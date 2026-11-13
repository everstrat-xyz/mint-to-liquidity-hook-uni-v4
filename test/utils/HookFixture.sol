// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

import {MintToLiquidityHook} from "../../src/MintToLiquidityHook.sol";
import {MockIssuer} from "../mocks/MockIssuer.sol";
import {MockToken} from "../mocks/MockToken.sol";

/**
 * @notice Deploys a PoolManager, the hook, a mock issuer and a registered pool with no liquidity.
 * @dev Concrete fixtures pick the quote currency and which side of the pool the token is on, so
 * every test runs in each price orientation.
 */
abstract contract HookFixture is Test, Deployers {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for *;

    uint256 internal constant WAD = 1e18;
    uint256 internal constant Q192 = 1 << 192;

    uint24 internal constant POOL_FEE = 3000; // 0.3%
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant MINT_PREMIUM = 0.1e18; // mint 10% above NAV
    uint8 internal constant TOKEN_DECIMALS = 18;
    uint256 internal constant TOKEN_UNIT = 1e18;
    uint256 internal constant NAV_IN_QUOTE_UNITS = 2; // one token is worth two quote units

    uint256 internal constant HOLDER_TOKENS = 1_000_000e18;
    /// @dev Tokens and quote the PoolManager already holds for other pools. `take` draws on them.
    uint256 internal constant MANAGER_TOKEN_RESERVE = 100_000e18;
    uint256 internal constant MANAGER_QUOTE_RESERVE_UNITS = 1_000_000;
    uint256 internal constant HOLDER_QUOTE_UNITS = 10_000_000;
    /// @dev ETH attached to native-quote router calls; the router refunds what it does not use.
    uint256 internal constant NATIVE_CALL_VALUE = 5_000_000 ether;

    /// @dev Addresses whose order decides which side of an ERC-20 pool the token is on.
    address internal constant LOW_ADDRESS = address(0x1111111111111111111111111111111111111111);
    address internal constant HIGH_ADDRESS = address(0x9999999999999999999999999999999999999999);

    MintToLiquidityHook internal hook;
    MockIssuer internal issuer;
    MockToken internal token;
    MockToken internal quoteToken;
    Currency internal tokenCurrency;
    Currency internal quoteCurrency;
    PoolKey internal poolKey;
    PoolId internal poolId;
    bool internal tokenIsCurrency0;

    address internal beneficiary = makeAddr("beneficiary");
    address internal issuerOwner = makeAddr("issuerOwner");

    /*//////////////////////////////////////////////////////////////
                             CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    function _quoteIsNative() internal pure virtual returns (bool);

    /// @dev Only used for an ERC-20 quote; with native ETH the token is always `currency1`.
    function _wantTokenAsCurrency0() internal pure virtual returns (bool);

    function _quoteDecimals() internal pure virtual returns (uint8) {
        return 18;
    }

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        deployFreshManagerAndRouters();

        address _hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("MintToLiquidityHook.sol:MintToLiquidityHook", abi.encode(manager), _hookAddress);
        hook = MintToLiquidityHook(payable(_hookAddress));

        _deployCurrencies();
        issuer = new MockIssuer(token, quoteCurrency, issuerOwner, beneficiary, MINT_PREMIUM);

        // Supply first, then NAV: the issuer is fully backed and fully liquid.
        token.mint(address(this), HOLDER_TOKENS);
        token.mint(address(manager), MANAGER_TOKEN_RESERVE);
        issuer.setNav(NAV_IN_QUOTE_UNITS * _quoteUnit());
        _dealQuote(address(issuer), issuer.assets());

        _dealQuote(address(manager), MANAGER_QUOTE_RESERVE_UNITS * _quoteUnit());
        _dealQuote(address(this), HOLDER_QUOTE_UNITS * _quoteUnit());
        if (_quoteIsNative()) vm.deal(address(this), address(this).balance + 2 * NATIVE_CALL_VALUE);

        token.approve(address(swapRouter), type(uint256).max);
        token.approve(address(modifyLiquidityRouter), type(uint256).max);
        if (!_quoteIsNative()) {
            quoteToken.approve(address(swapRouter), type(uint256).max);
            quoteToken.approve(address(modifyLiquidityRouter), type(uint256).max);
        }

        vm.prank(issuerOwner);
        poolKey = hook.registerPool(issuer, POOL_FEE, TICK_SPACING);
        poolId = poolKey.toId();
        tokenIsCurrency0 = poolKey.currency0 == tokenCurrency;
    }

    function _deployCurrencies() private {
        if (_quoteIsNative()) {
            token = new MockToken("Token", "TKN", TOKEN_DECIMALS);
            quoteCurrency = Currency.wrap(address(0));
        } else {
            (address _tokenAddress, address _quoteAddress) =
                _wantTokenAsCurrency0() ? (LOW_ADDRESS, HIGH_ADDRESS) : (HIGH_ADDRESS, LOW_ADDRESS);
            deployCodeTo("MockToken.sol:MockToken", abi.encode("Token", "TKN", TOKEN_DECIMALS), _tokenAddress);
            deployCodeTo("MockToken.sol:MockToken", abi.encode("Quote", "QTE", _quoteDecimals()), _quoteAddress);
            token = MockToken(_tokenAddress);
            quoteToken = MockToken(_quoteAddress);
            quoteCurrency = Currency.wrap(_quoteAddress);
        }
        tokenCurrency = Currency.wrap(address(token));
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @dev Swaps through the v4 test router with no price limit.
     * @return _tokens Tokens the holder received (buy) or paid (sell).
     * @return _quote Quote the holder paid (buy) or received (sell).
     */
    function _swap(bool _isBuy, bool _exactInput, uint256 _amount) internal returns (uint256 _tokens, uint256 _quote) {
        bool _zeroForOne = _isBuy != tokenIsCurrency0;

        return _swapWithLimit(_isBuy, _exactInput, _amount, _zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT);
    }

    function _swapWithLimit(bool _isBuy, bool _exactInput, uint256 _amount, uint160 _sqrtPriceLimitX96)
        internal
        returns (uint256 _tokens, uint256 _quote)
    {
        uint256 _tokensBefore = token.balanceOf(address(this));
        uint256 _quoteBefore = _quoteBalance(address(this));

        swapRouter.swap{value: _quoteIsNative() && _isBuy ? NATIVE_CALL_VALUE : 0}(
            poolKey,
            SwapParams({
                zeroForOne: _isBuy != tokenIsCurrency0,
                amountSpecified: _exactInput ? -int256(_amount) : int256(_amount),
                sqrtPriceLimitX96: _sqrtPriceLimitX96
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );

        _tokens = _absDiff(token.balanceOf(address(this)), _tokensBefore);
        _quote = _absDiff(_quoteBalance(address(this)), _quoteBefore);
    }

    function _addFullRangeLiquidity(uint256 _liquidity) internal {
        _modifyLiquidity(TickMath.minUsableTick(TICK_SPACING), TickMath.maxUsableTick(TICK_SPACING), int256(_liquidity));
    }

    function _modifyLiquidity(int24 _tickLower, int24 _tickUpper, int256 _liquidityDelta) internal {
        modifyLiquidityRouter.modifyLiquidity{value: _quoteIsNative() && _liquidityDelta > 0 ? NATIVE_CALL_VALUE : 0}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: _tickLower, tickUpper: _tickUpper, liquidityDelta: _liquidityDelta, salt: bytes32(0)
            }),
            ZERO_BYTES
        );
    }

    /// @dev Moves the issuer's NAV by `_factor` (WAD), leaving the pool price where it is.
    function _scaleNav(uint256 _factor) internal {
        issuer.setNav((issuer.nav() * _factor) / WAD);
    }

    function _dealQuote(address _to, uint256 _amount) internal {
        if (_quoteIsNative()) vm.deal(_to, _to.balance + _amount);
        else quoteToken.mint(_to, _amount);
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    /// @dev One whole quote token in base units.
    function _quoteUnit() internal pure returns (uint256) {
        return 10 ** _quoteDecimals();
    }

    /// @dev Full-range liquidity worth roughly 10,000 tokens a side at the starting price.
    function _defaultLiquidity() internal pure returns (uint256) {
        return 10_000 * 10 ** ((TOKEN_DECIMALS + _quoteDecimals()) / 2);
    }

    function _quoteBalance(address _owner) internal view returns (uint256) {
        return quoteCurrency.balanceOf(_owner);
    }

    function _sqrtPrice() internal view returns (uint160 _sqrtPriceX96) {
        (_sqrtPriceX96,,,) = manager.getSlot0(poolId);
    }

    /// @dev The pool's token price, quote per token, WAD.
    function _poolPrice() internal view returns (uint256) {
        uint256 _sqrtPriceX96 = _sqrtPrice();
        uint256 _ratioX192 = _sqrtPriceX96 * _sqrtPriceX96;

        return tokenIsCurrency0 ? FullMath.mulDiv(_ratioX192, WAD, Q192) : FullMath.mulDiv(Q192, WAD, _ratioX192);
    }

    function _band() internal view returns (IMintToLiquidityHook.Band memory _currentBand) {
        bool _valid;
        (_valid, _currentBand) = hook.getBand(poolId);
        assertTrue(_valid, "band is invalid");
    }

    function _assertHookHoldsNothing() internal view {
        assertEq(token.balanceOf(address(hook)), 0, "hook holds tokens");
        assertEq(_quoteBalance(address(hook)), 0, "hook holds quote");
    }

    function _absDiff(uint256 _a, uint256 _b) internal pure returns (uint256) {
        return _a > _b ? _a - _b : _b - _a;
    }

    /// @dev A key for a pool on this hook that no adapter registered.
    function _unregisteredKey() internal view returns (PoolKey memory) {
        return PoolKey({
            currency0: poolKey.currency0,
            currency1: poolKey.currency1,
            fee: POOL_FEE + 1,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }
}
