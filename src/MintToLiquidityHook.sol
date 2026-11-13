// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/utils/CurrencySettler.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SafeCast} from "@uniswap/v4-core/src/libraries/SafeCast.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {BalanceDelta} from "@uniswap/v4-core/src/types/BalanceDelta.sol";
import {
    BeforeSwapDelta,
    BeforeSwapDeltaLibrary,
    toBeforeSwapDelta
} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IIssuerAdapter} from "interfaces/IIssuerAdapter.sol";
import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

/**
 * @title MintToLiquidityHook
 * @notice Gives a mintable token a market from its first block by turning its issuer's mint and
 * redemption prices into the pool's band.
 *
 * The pool is an ordinary concentrated-liquidity pool. The hook adds no pricing of its own:
 *
 * 1. Market of last resort. When the pool cannot fill a swap inside the band, the hook fills it from
 *    the issuer: buys are minted at the ceiling, sells are redeemed at the floor.
 * 2. Band keeper. When the pool price leaves the band, the hook mints or redeems through the issuer
 *    and trades the price back to the band edge, sending the profit to the issuer's beneficiary.
 *
 * Every issuer interaction runs inside a self-call that can unwind, so a failing issuer never blocks
 * a swap: the swap goes to the curve as if the hook were not there.
 *
 * @dev Prototype. Unaudited and not for mainnet use.
 */
contract MintToLiquidityHook is BaseHook, IMintToLiquidityHook, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using LPFeeLibrary for uint24;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintToLiquidityHook
    uint256 public constant ROUNDING_SLACK = 1;

    /// @dev Largest amount a rebalance swap asks for; the price limit is what stops it.
    int256 private constant _MAX_SWAP_AMOUNT = type(int128).max;

    /// @dev Transient slot of the reentrancy flag.
    bytes32 private constant _BUSY_SLOT = keccak256("MintToLiquidityHook.busy");

    /// @dev Transient slot of the flag `beforeSwap` leaves for `afterSwap` when it filled the whole swap.
    bytes32 private constant _FILLED_SLOT = keccak256("MintToLiquidityHook.filled");

    /// @dev Seed of the transient slots that cache a pool's band for one transaction.
    bytes32 private constant _BAND_SLOT_SEED = keccak256("MintToLiquidityHook.band");

    /// @dev States of a pool's cached band. Unset is transient storage's default.
    uint256 private constant _BAND_VALID = 1;
    uint256 private constant _BAND_INVALID = 2;

    /*//////////////////////////////////////////////////////////////
                            STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    mapping(PoolId poolId => PoolConfig config) private _pools;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlySelf() {
        if (msg.sender != address(this)) revert MintToLiquidityHookCallerNotSelf();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    /**
     * @notice Receives native ETH taken from the PoolManager or paid out by an adapter.
     */
    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                           EXTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IMintToLiquidityHook
    function registerPool(IIssuerAdapter _adapter, uint24 _fee, int24 _tickSpacing)
        external
        returns (PoolKey memory _key)
    {
        if (address(_adapter) == address(0)) revert MintToLiquidityHookZeroAddress();
        if (msg.sender != _adapter.owner()) revert MintToLiquidityHookNotAdapterOwner();
        if (_fee.isDynamicFee()) revert MintToLiquidityHookDynamicFeeNotSupported();

        Currency _token = Currency.wrap(address(_adapter.token()));
        Currency _quote = _adapter.quoteCurrency();
        if (_token.isAddressZero() || _token == _quote) revert MintToLiquidityHookInvalidCurrencies();

        bool _tokenIsCurrency0 = _token < _quote;
        _key = PoolKey({
            currency0: _tokenIsCurrency0 ? _token : _quote,
            currency1: _tokenIsCurrency0 ? _quote : _token,
            fee: _fee,
            tickSpacing: _tickSpacing,
            hooks: IHooks(address(this))
        });

        PoolId _poolId = _key.toId();
        if (address(_pools[_poolId].adapter) != address(0)) revert MintToLiquidityHookPoolAlreadyRegistered();

        (bool _valid, Band memory _band) =
            BandMath.buildBand(_adapter.mintPrice(), _adapter.redeemPrice(), _tokenIsCurrency0);
        if (!_valid) revert MintToLiquidityHookInvalidBand();

        _pools[_poolId] = PoolConfig({adapter: _adapter, tokenIsCurrency0: _tokenIsCurrency0});

        uint160 _sqrtPriceX96 = BandMath.midSqrtPriceX96(_band, _tokenIsCurrency0);
        emit PoolRegistered(_poolId, _adapter, _tokenIsCurrency0, _sqrtPriceX96);

        // `beforeInitialize` only lets registered pools through, so the binding is stored first.
        poolManager.initialize(_key, _sqrtPriceX96);
    }

    /// @inheritdoc IMintToLiquidityHook
    function rebalance(PoolKey calldata _key) external returns (bool _ran) {
        return abi.decode(poolManager.unlock(abi.encode(_key)), (bool));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata _data) external onlyPoolManager returns (bytes memory) {
        PoolKey memory _key = abi.decode(_data, (PoolKey));

        _setBusy(true);
        bool _ran = _rebalance(_key);
        _setBusy(false);

        return abi.encode(_ran);
    }

    /// @inheritdoc IMintToLiquidityHook
    function rebalanceInternal(PoolKey calldata _key) external onlySelf {
        _rebalance(_key);
    }

    /// @inheritdoc IMintToLiquidityHook
    function fillInternal(PoolKey calldata _key, SwapParams calldata _params)
        external
        onlySelf
        returns (BeforeSwapDelta _delta)
    {
        return _fill(_key, _params);
    }

    /// @inheritdoc IMintToLiquidityHook
    function poolConfig(PoolId _poolId) external view returns (PoolConfig memory) {
        return _pools[_poolId];
    }

    /// @inheritdoc IMintToLiquidityHook
    function getBand(PoolId _poolId) external view returns (bool _valid, Band memory _band) {
        PoolConfig memory _config = _pools[_poolId];
        if (address(_config.adapter) == address(0)) revert MintToLiquidityHookPoolNotRegistered();

        return BandMath.buildBand(_config.adapter.mintPrice(), _config.adapter.redeemPrice(), _config.tokenIsCurrency0);
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc BaseHook
    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    /*//////////////////////////////////////////////////////////////
                             HOOK CALLBACKS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Only pools registered with an adapter can be initialised with this hook.
     */
    function _beforeInitialize(address, PoolKey calldata _key, uint160) internal view override returns (bytes4) {
        if (address(_pools[_key.toId()].adapter) == address(0)) revert MintToLiquidityHookPoolNotRegistered();

        return IHooks.beforeInitialize.selector;
    }

    /**
     * @dev Corrects drift since the last trade, then fills the swap from the issuer when the pool
     * cannot fill it inside the band. A swap that re-enters while the hook is mid-operation is left
     * to the curve.
     */
    function _beforeSwap(address, PoolKey calldata _key, SwapParams calldata _params, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        BeforeSwapDelta _delta = BeforeSwapDeltaLibrary.ZERO_DELTA;

        if (!_isBusy()) {
            _setBusy(true);
            _tryRebalance(_key, _params, true);
            _delta = _tryFill(_key, _params);
            _setBusy(false);

            // A swap the issuer filled in full never reaches the curve, so the price cannot have
            // moved and `afterSwap` has nothing to correct. Skipping it saves a second band read.
            if (int256(BeforeSwapDeltaLibrary.getSpecifiedDelta(_delta)) == -_params.amountSpecified) {
                _setFlag(_FILLED_SLOT, true);
            }
        }

        return (IHooks.beforeSwap.selector, _delta, 0);
    }

    /**
     * @dev Corrects the swapper's own push past a band edge.
     */
    function _afterSwap(address, PoolKey calldata _key, SwapParams calldata _params, BalanceDelta, bytes calldata)
        internal
        override
        returns (bytes4, int128)
    {
        if (_getFlag(_FILLED_SLOT)) {
            _setFlag(_FILLED_SLOT, false);
        } else if (!_isBusy()) {
            _setBusy(true);
            _tryRebalance(_key, _params, false);
            _setBusy(false);
        }

        return (IHooks.afterSwap.selector, 0);
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCING
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Rebalances when the price is outside the band, swallowing any failure.
     * @param _beforeUserSwap True in `beforeSwap`. A rebalance there moves the price before the
     * user's swap runs, so it is skipped when it would carry the price to or past the user's limit,
     * which v4 rejects. `afterSwap` picks the correction up instead.
     */
    function _tryRebalance(PoolKey calldata _key, SwapParams calldata _params, bool _beforeUserSwap) internal {
        PoolId _poolId = _key.toId();
        PoolConfig memory _config = _pools[_poolId];

        (bool _valid, Band memory _band) = _loadBand(_poolId, _config);
        if (!_valid) return;

        (uint160 _sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
        bool _above = BandMath.isAboveCeiling(_sqrtPriceX96, _band, _config.tokenIsCurrency0);
        if (!_above && !BandMath.isBelowFloor(_sqrtPriceX96, _band, _config.tokenIsCurrency0)) return;

        if (_beforeUserSwap) {
            // From above the hook sells the token; from below it buys it.
            bool _zeroForOne = _above == _config.tokenIsCurrency0;
            uint160 _target = _above ? _band.sqrtCeilingX96 : _band.sqrtFloorX96;
            if (
                _params.zeroForOne == _zeroForOne
                    && (_zeroForOne ? _params.sqrtPriceLimitX96 >= _target : _params.sqrtPriceLimitX96 <= _target)
            ) return;
        }

        try this.rebalanceInternal(_key) {}
        catch (bytes memory _reason) {
            emit RebalanceSkipped(_poolId, _reason);
        }
    }

    /**
     * @dev Trades the pool price back to the nearest band edge through the issuer. Reverts when the
     * issuer does, when the trade would lose money, or when there is no exit capacity to buy with.
     * @return _ran False when the price was already inside the band.
     */
    function _rebalance(PoolKey memory _key) internal returns (bool _ran) {
        PoolId _poolId = _key.toId();
        PoolConfig memory _config = _pools[_poolId];
        if (address(_config.adapter) == address(0)) revert MintToLiquidityHookPoolNotRegistered();

        (bool _valid, Band memory _band) = _loadBand(_poolId, _config);
        if (!_valid) revert MintToLiquidityHookInvalidBand();

        (uint160 _sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);

        if (BandMath.isAboveCeiling(_sqrtPriceX96, _band, _config.tokenIsCurrency0)) {
            _rebalanceFromAbove(_key, _poolId, _config, _band);
            return true;
        }
        if (BandMath.isBelowFloor(_sqrtPriceX96, _band, _config.tokenIsCurrency0)) {
            _rebalanceFromBelow(_key, _poolId, _config, _band);
            return true;
        }
    }

    /**
     * @dev Pool price above the mint price: sell tokens into the pool down to the ceiling, mint them
     * at the ceiling, keep the difference.
     */
    function _rebalanceFromAbove(PoolKey memory _key, PoolId _poolId, PoolConfig memory _config, Band memory _band)
        internal
    {
        BalanceDelta _delta = poolManager.swap(
            _key,
            SwapParams({
                zeroForOne: _config.tokenIsCurrency0,
                amountSpecified: -_MAX_SWAP_AMOUNT,
                sqrtPriceLimitX96: _band.sqrtCeilingX96
            }),
            ""
        );
        (int128 _tokenDelta, int128 _quoteDelta) = _split(_delta, _config.tokenIsCurrency0);
        uint256 _tokens = uint256(uint128(-_tokenDelta));
        uint256 _quote = uint256(uint128(_quoteDelta));

        (Currency _tokenCurrency, Currency _quoteCurrency) = _currencies(_key, _config.tokenIsCurrency0);

        // After the LP fee the pool can pay less than the tokens cost to mint.
        uint256 _cost = BandMath.quoteForTokensUp(_tokens, _band.ceiling);
        if (_quote < _cost) revert MintToLiquidityHookUnprofitableRebalance();

        // With no liquidity in the way the price moves to the ceiling for free and there is nothing
        // to mint. Dust liquidity can still pay a few base units of quote for no tokens at all, and
        // that credit has to be taken or the PoolManager would reject the whole transaction.
        uint256 _profit;
        if (_quote != 0) {
            _quoteCurrency.take(poolManager, address(this), _quote, false);
            if (_tokens != 0) {
                _mint(_config.adapter, _quoteCurrency, _cost, _tokens);
                _tokenCurrency.settle(poolManager, address(this), _tokens, false);
                _clearBand(_poolId);
            }
            _profit = _sweep(_config.adapter, _tokenCurrency, _quoteCurrency);
        }

        emit Rebalanced(_poolId, true, _tokens, _quote, _profit);
    }

    /**
     * @dev Pool price below the redemption price: buy tokens from the pool up to the floor, redeem
     * them at the floor, keep the difference. The purchase is capped at what the issuer can pay out
     * now, so beyond that capacity the floor is soft.
     */
    function _rebalanceFromBelow(PoolKey memory _key, PoolId _poolId, PoolConfig memory _config, Band memory _band)
        internal
    {
        uint256 _maxTokens = Math.min(
            BandMath.tokensForQuoteDown(_exitCapacity(_config.adapter), _band.floor), uint256(_MAX_SWAP_AMOUNT)
        );
        if (_maxTokens == 0) revert MintToLiquidityHookNoExitCapacity();

        BalanceDelta _delta = poolManager.swap(
            _key,
            SwapParams({
                zeroForOne: !_config.tokenIsCurrency0,
                amountSpecified: int256(_maxTokens),
                sqrtPriceLimitX96: _band.sqrtFloorX96
            }),
            ""
        );
        (int128 _tokenDelta, int128 _quoteDelta) = _split(_delta, _config.tokenIsCurrency0);
        uint256 _tokens = uint256(uint128(_tokenDelta));
        uint256 _quote = uint256(uint128(-_quoteDelta));

        // With no liquidity in the way the price moves to the floor for free. Dust liquidity can
        // charge a few base units of quote for no tokens at all; the hook has nothing to pay that with.
        uint256 _profit;
        if (_tokens == 0) {
            if (_quote != 0) revert MintToLiquidityHookUnprofitableRebalance();
        } else {
            (Currency _tokenCurrency, Currency _quoteCurrency) = _currencies(_key, _config.tokenIsCurrency0);

            // The redemption has to cover what the pool is owed; a losing trade reverts here.
            _tokenCurrency.take(poolManager, address(this), _tokens, false);
            _redeem(_config.adapter, _tokenCurrency, _tokens, _quote);
            _quoteCurrency.settle(poolManager, address(this), _quote, false);

            _clearBand(_poolId);
            _profit = _sweep(_config.adapter, _tokenCurrency, _quoteCurrency);
        }

        emit Rebalanced(_poolId, false, _tokens, _quote, _profit);
    }

    /*//////////////////////////////////////////////////////////////
                              DIRECT FILLS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Fills the swap from the issuer when the pool has no active liquidity or its price is at
     * the band edge the swap is heading for, swallowing any failure.
     */
    function _tryFill(PoolKey calldata _key, SwapParams calldata _params) internal returns (BeforeSwapDelta) {
        PoolId _poolId = _key.toId();
        PoolConfig memory _config = _pools[_poolId];

        (bool _valid, Band memory _band) = _loadBand(_poolId, _config);
        if (!_valid) return BeforeSwapDeltaLibrary.ZERO_DELTA;

        bool _isBuy = _params.zeroForOne != _config.tokenIsCurrency0;

        if (poolManager.getLiquidity(_poolId) != 0) {
            (uint160 _sqrtPriceX96,,,) = poolManager.getSlot0(_poolId);
            if (!BandMath.isAtEdge(_sqrtPriceX96, _band, _config.tokenIsCurrency0, _isBuy)) {
                return BeforeSwapDeltaLibrary.ZERO_DELTA;
            }
        }

        // The fill is priced at the band edge, so the swapper's price limit has to allow it.
        uint160 _edge = _isBuy ? _band.sqrtCeilingX96 : _band.sqrtFloorX96;
        if (_params.zeroForOne ? _params.sqrtPriceLimitX96 > _edge : _params.sqrtPriceLimitX96 < _edge) {
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }

        try this.fillInternal(_key, _params) returns (BeforeSwapDelta _delta) {
            return _delta;
        } catch (bytes memory _reason) {
            emit DirectFillSkipped(_poolId, _reason);
            return BeforeSwapDeltaLibrary.ZERO_DELTA;
        }
    }

    /**
     * @dev Mints at the ceiling or redeems at the floor for as much of the swap as the issuer and
     * the PoolManager's reserves allow. Whatever is left goes to the curve.
     * @return The hook's delta: what it took of the input and paid of the output.
     */
    function _fill(PoolKey memory _key, SwapParams memory _params) internal returns (BeforeSwapDelta) {
        PoolId _poolId = _key.toId();
        PoolConfig memory _config = _pools[_poolId];

        (bool _valid, Band memory _band) = _loadBand(_poolId, _config);
        if (!_valid) revert MintToLiquidityHookInvalidBand();

        (Currency _tokenCurrency, Currency _quoteCurrency) = _currencies(_key, _config.tokenIsCurrency0);
        bool _isBuy = _params.zeroForOne != _config.tokenIsCurrency0;
        bool _exactInput = _params.amountSpecified < 0;
        uint256 _amount = _exactInput ? uint256(-_params.amountSpecified) : uint256(_params.amountSpecified);

        (uint256 _tokens, uint256 _quote) = _isBuy
            ? _fillBuy(_config.adapter, _tokenCurrency, _quoteCurrency, _band.ceiling, _exactInput, _amount)
            : _fillSell(_config.adapter, _tokenCurrency, _quoteCurrency, _band.floor, _exactInput, _amount);

        _clearBand(_poolId);
        _sweep(_config.adapter, _tokenCurrency, _quoteCurrency);

        emit DirectFilled(_poolId, _isBuy, _tokens, _quote, _isBuy ? _band.ceiling : _band.floor);

        int128 _taken = (_isBuy ? _quote : _tokens).toInt128();
        int128 _paid = -(_isBuy ? _tokens : _quote).toInt128();

        // The specified currency is the input of an exact-input swap and the output of an exact-output one.
        return _exactInput ? toBeforeSwapDelta(_taken, _paid) : toBeforeSwapDelta(_paid, _taken);
    }

    /**
     * @dev Buy: take the quote from the PoolManager, mint at the ceiling, pay the tokens in.
     * Capped at the quote the PoolManager holds, which is all `take` can hand over before the
     * swapper has paid.
     */
    function _fillBuy(
        IIssuerAdapter _adapter,
        Currency _tokenCurrency,
        Currency _quoteCurrency,
        uint256 _ceiling,
        bool _exactInput,
        uint256 _amount
    ) internal returns (uint256 _tokens, uint256 _quote) {
        uint256 _available = _quoteCurrency.balanceOf(address(poolManager));

        if (_exactInput) {
            _quote = Math.min(_amount, _available);
            _tokens = BandMath.tokensForQuoteDown(_quote, _ceiling);
        } else {
            _tokens = _amount;
            _quote = BandMath.quoteForTokensUp(_tokens, _ceiling);
            if (_quote > _available) {
                _quote = _available;
                _tokens = BandMath.tokensForQuoteDown(_quote, _ceiling);
            }
        }
        if (_tokens == 0) revert MintToLiquidityHookNothingToFill();

        _quoteCurrency.take(poolManager, address(this), _quote, false);
        _mint(_adapter, _quoteCurrency, _quote, _tokens);
        _tokenCurrency.settle(poolManager, address(this), _tokens, false);
    }

    /**
     * @dev Sell: take the tokens from the PoolManager, redeem at the floor, pay the quote in.
     * Capped at the issuer's immediate exit capacity and at the tokens the PoolManager holds, which
     * is all `take` can hand over before the swapper has paid. The swapper is paid `ROUNDING_SLACK`
     * below the floor so an issuer that rounds twice still covers the fill.
     */
    function _fillSell(
        IIssuerAdapter _adapter,
        Currency _tokenCurrency,
        Currency _quoteCurrency,
        uint256 _floor,
        bool _exactInput,
        uint256 _amount
    ) internal returns (uint256 _tokens, uint256 _quote) {
        uint256 _capacity = _exitCapacity(_adapter);
        uint256 _available = _tokenCurrency.balanceOf(address(poolManager));
        uint256 _gross;

        // Size the fill from what the swapper asked for, then shrink it to what the PoolManager holds
        // and what the issuer can pay out now.
        _tokens = _exactInput ? _amount : BandMath.tokensForQuoteUp(_amount + ROUNDING_SLACK, _floor);
        _tokens = Math.min(_tokens, _available);

        // The issuer pays `floor(tokens * price)`. When that is above the capacity it would queue, so
        // round the tokens down to what the capacity covers: rounding them up overshoots it.
        if (BandMath.quoteForTokensDown(_tokens, _floor) > _capacity) {
            _tokens = BandMath.tokensForQuoteDown(_capacity, _floor);
        }
        _gross = BandMath.quoteForTokensDown(_tokens, _floor);
        if (_gross <= ROUNDING_SLACK) revert MintToLiquidityHookNothingToFill();
        _quote = _gross - ROUNDING_SLACK;
        // Rounded-up tokens can be worth more than an exact output asked for; the surplus is swept.
        if (!_exactInput && _quote > _amount) _quote = _amount;

        _tokenCurrency.take(poolManager, address(this), _tokens, false);
        _redeem(_adapter, _tokenCurrency, _tokens, _quote);
        _quoteCurrency.settle(poolManager, address(this), _quote, false);
    }

    /*//////////////////////////////////////////////////////////////
                           ISSUER INTERACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Mints through the adapter, approving exactly the quote it pulls when that is an ERC-20.
     * The returned amount is not trusted: settling with the PoolManager fails if the tokens are short.
     */
    function _mint(IIssuerAdapter _adapter, Currency _quoteCurrency, uint256 _quoteIn, uint256 _minTokens) internal {
        if (_quoteCurrency.isAddressZero()) {
            _adapter.mint{value: _quoteIn}(_quoteIn, _minTokens);
            return;
        }

        IERC20 _quoteToken = IERC20(Currency.unwrap(_quoteCurrency));
        _quoteToken.forceApprove(address(_adapter), _quoteIn);
        _adapter.mint(_quoteIn, _minTokens);
        _revokeApproval(_quoteToken, address(_adapter));
    }

    /**
     * @dev Redeems through the adapter, approving exactly the tokens it pulls. The returned amount
     * is not trusted: settling with the PoolManager fails if the quote is short.
     */
    function _redeem(IIssuerAdapter _adapter, Currency _tokenCurrency, uint256 _tokens, uint256 _minQuote) internal {
        IERC20 _token = IERC20(Currency.unwrap(_tokenCurrency));
        _token.forceApprove(address(_adapter), _tokens);
        _adapter.redeem(_tokens, _minQuote);
        _revokeApproval(_token, address(_adapter));
    }

    /**
     * @dev Sends everything the hook holds of the pool's two currencies to the beneficiary, so the
     * hook carries no balance out of an operation. Runs last: the recipient gets control here.
     * @return _profit The quote swept.
     */
    function _sweep(IIssuerAdapter _adapter, Currency _tokenCurrency, Currency _quoteCurrency)
        internal
        returns (uint256 _profit)
    {
        address _beneficiary = _adapter.beneficiary();
        if (_beneficiary == address(0)) revert MintToLiquidityHookZeroAddress();

        uint256 _tokenDust = _tokenCurrency.balanceOfSelf();
        if (_tokenDust != 0) _tokenCurrency.transfer(_beneficiary, _tokenDust);

        _profit = _quoteCurrency.balanceOfSelf();
        if (_profit != 0) _quoteCurrency.transfer(_beneficiary, _profit);
    }

    /**
     * @dev Clears whatever allowance a call left behind.
     */
    function _revokeApproval(IERC20 _asset, address _spender) internal {
        if (_asset.allowance(address(this), _spender) != 0) _asset.forceApprove(_spender, 0);
    }

    /**
     * @dev The issuer's immediate exit capacity, capped so amounts derived from it cannot overflow.
     */
    function _exitCapacity(IIssuerAdapter _adapter) internal view returns (uint256) {
        return Math.min(_adapter.maxRedeemNow(), type(uint128).max);
    }

    /*//////////////////////////////////////////////////////////////
                               BAND CACHE
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Returns the pool's band, reading it from the adapter at most once per transaction unless
     * the hook trades with the issuer in between (which moves the issuer's prices, see `_clearBand`).
     * A band that is invalid or cannot be read is cached as such, so the hook stands aside for the
     * rest of the transaction.
     */
    function _loadBand(PoolId _poolId, PoolConfig memory _config) internal returns (bool _valid, Band memory _band) {
        bytes32 _slot = _bandSlot(_poolId);

        uint256 _status;
        uint256 _ceiling;
        uint256 _floor;
        uint256 _sqrtCeilingX96;
        uint256 _sqrtFloorX96;
        assembly ("memory-safe") {
            _status := tload(_slot)
            _ceiling := tload(add(_slot, 1))
            _floor := tload(add(_slot, 2))
            _sqrtCeilingX96 := tload(add(_slot, 3))
            _sqrtFloorX96 := tload(add(_slot, 4))
        }

        if (_status == _BAND_INVALID) return (false, _band);
        if (_status == _BAND_VALID) {
            // Safe: both were stored from `uint160` values.
            return (true, Band(_ceiling, _floor, uint160(_sqrtCeilingX96), uint160(_sqrtFloorX96)));
        }

        try _config.adapter.mintPrice() returns (uint256 _mintPrice) {
            _ceiling = _mintPrice;
        } catch {}
        if (_ceiling != 0) {
            try _config.adapter.redeemPrice() returns (uint256 _redeemPrice) {
                _floor = _redeemPrice;
            } catch {
                _ceiling = 0;
            }
        }

        (_valid, _band) = BandMath.buildBand(_ceiling, _floor, _config.tokenIsCurrency0);
        if (!_valid) emit BandInvalidated(_poolId, _ceiling, _floor);

        _status = _valid ? _BAND_VALID : _BAND_INVALID;
        _ceiling = _band.ceiling;
        _floor = _band.floor;
        _sqrtCeilingX96 = _band.sqrtCeilingX96;
        _sqrtFloorX96 = _band.sqrtFloorX96;
        assembly ("memory-safe") {
            tstore(_slot, _status)
            tstore(add(_slot, 1), _ceiling)
            tstore(add(_slot, 2), _floor)
            tstore(add(_slot, 3), _sqrtCeilingX96)
            tstore(add(_slot, 4), _sqrtFloorX96)
        }
    }

    /**
     * @dev Forgets the cached band. Called after every mint or redemption the hook makes, because a
     * trade with the issuer can move the issuer's prices (a mint at a premium raises the redemption
     * price), and the next decision in this transaction has to see the new band.
     */
    function _clearBand(PoolId _poolId) internal {
        bytes32 _slot = _bandSlot(_poolId);
        assembly ("memory-safe") {
            tstore(_slot, 0)
        }
    }

    function _bandSlot(PoolId _poolId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_poolId, _BAND_SLOT_SEED));
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _isBusy() internal view returns (bool) {
        return _getFlag(_BUSY_SLOT);
    }

    function _setBusy(bool _busy) internal {
        _setFlag(_BUSY_SLOT, _busy);
    }

    function _getFlag(bytes32 _slot) internal view returns (bool _value) {
        assembly ("memory-safe") {
            _value := tload(_slot)
        }
    }

    function _setFlag(bytes32 _slot, bool _value) internal {
        assembly ("memory-safe") {
            tstore(_slot, _value)
        }
    }

    /**
     * @dev The pool's currencies as (token, quote).
     */
    function _currencies(PoolKey memory _key, bool _tokenIsCurrency0) internal pure returns (Currency, Currency) {
        return _tokenIsCurrency0 ? (_key.currency0, _key.currency1) : (_key.currency1, _key.currency0);
    }

    /**
     * @dev A swap's balance delta as (token, quote).
     */
    function _split(BalanceDelta _delta, bool _tokenIsCurrency0) internal pure returns (int128, int128) {
        return _tokenIsCurrency0 ? (_delta.amount0(), _delta.amount1()) : (_delta.amount1(), _delta.amount0());
    }
}
