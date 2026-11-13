// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

import {MintToLiquidityHook} from "../../src/MintToLiquidityHook.sol";
import {MockIssuer} from "../mocks/MockIssuer.sol";
import {MockToken} from "../mocks/MockToken.sol";

/**
 * @notice Drives the pool, the issuer and the hook with random actions and counts every time one of
 * the README §8 invariants is broken. The invariant test asserts the counters stay at zero.
 */
contract HookHandler is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    struct Setup {
        IPoolManager manager;
        PoolSwapTest swapRouter;
        PoolModifyLiquidityTest modifyLiquidityRouter;
        MintToLiquidityHook hook;
        MockIssuer issuer;
        MockToken token;
        MockToken quoteToken;
        PoolKey poolKey;
        address beneficiary;
        uint256 quoteUnit;
        uint256 liquidityUnit;
    }

    uint256 internal constant WAD = 1e18;
    uint256 internal constant NATIVE_CALL_VALUE = 1_000_000 ether;

    uint256 internal constant MAX_TRADE_TOKENS = 2_000e18;
    uint256 internal constant MIN_TRADE_TOKENS = 1e15;
    uint256 internal constant MAX_TRADE_QUOTE_UNITS = 4_000;
    uint256 internal constant QUOTE_DUST_DIVISOR = 1_000; // smallest quote trade is 1/1000 of a unit
    uint256 internal constant MAX_LIQUIDITY_UNITS = 10_000;
    uint256 internal constant MIN_NAV_FACTOR = 0.9e18;
    uint256 internal constant MAX_NAV_FACTOR = 1.1e18;
    uint256 internal constant MAX_EXIT_CAP_UNITS = 500;
    uint256 internal constant EXIT_CAP_MODES = 3;
    int24 internal constant TICK_SPACING = 60;

    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    Setup internal s;
    PoolId internal poolId;
    bool internal tokenIsCurrency0;
    bool internal quoteIsNative;
    Currency internal quoteCurrency;

    uint256 public liquidityAdded;
    uint256 public lastBeneficiaryQuote;

    // Ghost counters: each must stay zero.
    uint256 public swapReverts; // §8.6
    uint256 public fillPriceViolations; // §8.2
    uint256 public redeemPriceDrops; // §8.7
    uint256 public beneficiaryLosses; // §8.3
    uint256 public rebalanceBandViolations; // §8.1

    // Coverage counters: how often the interesting paths ran.
    uint256 public swaps;
    uint256 public directFills;
    uint256 public rebalances;
    bytes public lastSwapRevert;

    constructor(Setup memory _setup) {
        s = _setup;
        poolId = _setup.poolKey.toId();
        quoteCurrency = _setup.issuer.quoteCurrency();
        quoteIsNative = quoteCurrency.isAddressZero();
        tokenIsCurrency0 = Currency.unwrap(_setup.poolKey.currency0) == address(_setup.token);

        _setup.token.approve(address(_setup.swapRouter), type(uint256).max);
        _setup.token.approve(address(_setup.modifyLiquidityRouter), type(uint256).max);
        if (!quoteIsNative) {
            _setup.quoteToken.approve(address(_setup.swapRouter), type(uint256).max);
            _setup.quoteToken.approve(address(_setup.modifyLiquidityRouter), type(uint256).max);
        }
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                 SWAPS
    //////////////////////////////////////////////////////////////*/

    function buy(uint256 _amount, bool _exactInput) external {
        _amount = _exactInput
            ? bound(_amount, s.quoteUnit / QUOTE_DUST_DIVISOR, MAX_TRADE_QUOTE_UNITS * s.quoteUnit)
            : bound(_amount, MIN_TRADE_TOKENS, MAX_TRADE_TOKENS);
        _swap(true, _exactInput, _amount);
    }

    function sell(uint256 _amount, bool _exactInput) external {
        _amount = _exactInput
            ? bound(_amount, MIN_TRADE_TOKENS, MAX_TRADE_TOKENS)
            : bound(_amount, s.quoteUnit / QUOTE_DUST_DIVISOR, MAX_TRADE_QUOTE_UNITS * s.quoteUnit);
        _swap(false, _exactInput, _amount);
    }

    function _swap(bool _isBuy, bool _exactInput, uint256 _amount) internal {
        bool _zeroForOne = _isBuy != tokenIsCurrency0;
        uint160 _limit = _zeroForOne ? MIN_PRICE_LIMIT : MAX_PRICE_LIMIT;
        // v4 rejects a swap whose limit is already reached, with or without a hook.
        if (_sqrtPrice() == _limit) return;

        uint256 _redeemPriceBefore = s.issuer.nav();
        SwapParams memory _params = SwapParams({
            zeroForOne: _zeroForOne,
            amountSpecified: _exactInput ? -int256(_amount) : int256(_amount),
            sqrtPriceLimitX96: _limit
        });
        uint256 _value = quoteIsNative && _isBuy ? NATIVE_CALL_VALUE : 0;

        // §8.6 is about reverts the hook causes. An exact-output order for more than the pool holds
        // reverts on any v4 pool, so a failing swap only counts if it goes through with the hook
        // standing aside. The replay first lets the hook put the price back in the band: keeping
        // the band is the hook's job, and how deep the pool is afterwards is not a hook failure.
        uint256 _snapshot = vm.snapshotState();
        vm.recordLogs();
        try s.swapRouter.swap{value: _value}(s.poolKey, _params, _settings(), "") {
            swaps++;
        } catch (bytes memory _reason) {
            vm.revertToState(_snapshot);
            try s.hook.rebalance(s.poolKey) {} catch {}
            s.issuer.forcePrices(WAD, 2 * WAD); // an invalid band: the hook does nothing
            try s.swapRouter.swap{value: _value}(s.poolKey, _params, _settings(), "") {
                vm.revertToState(_snapshot);
                swapReverts++;
                lastSwapRevert = _reason;
            } catch {
                vm.revertToState(_snapshot);
            }
            return;
        }

        _checkLogs();
        _checkAfterHookTrade(_redeemPriceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                               REBALANCE
    //////////////////////////////////////////////////////////////*/

    function rebalance() external {
        (bool _valid, IMintToLiquidityHook.Band memory _band) = s.hook.getBand(poolId);
        if (!_valid) return;

        uint256 _redeemPriceBefore = s.issuer.nav();
        uint256 _capacityTokens = BandMath.tokensForQuoteDown(s.issuer.maxRedeemNow(), _band.floor);
        vm.recordLogs();

        try s.hook.rebalance(s.poolKey) returns (bool _ran) {
            if (_ran) {
                rebalances++;
                // §8.1: inside the band the hook traded against, or stopped at the exit capacity.
                uint160 _sqrtPriceX96 = _sqrtPrice();
                (bool _found, uint256 _tokens) = _lastRebalanceTokens();
                bool _capped = _found && _tokens == _capacityTokens;
                if (
                    BandMath.isAboveCeiling(_sqrtPriceX96, _band, tokenIsCurrency0)
                        || (BandMath.isBelowFloor(_sqrtPriceX96, _band, tokenIsCurrency0) && !_capped)
                ) rebalanceBandViolations++;
            }
        } catch {
            // The public rebalance is allowed to revert: paused issuer, no capacity, no profit.
            vm.getRecordedLogs();
        }

        _checkAfterHookTrade(_redeemPriceBefore);
    }

    /*//////////////////////////////////////////////////////////////
                           ISSUER AND LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    /// @dev NAV moves while the pool sits idle; a gain is backed by real quote.
    function driftNav(uint256 _factor) external {
        _factor = bound(_factor, MIN_NAV_FACTOR, MAX_NAV_FACTOR);
        s.issuer.setNav((s.issuer.nav() * _factor) / WAD);

        uint256 _balance = quoteCurrency.balanceOf(address(s.issuer));
        if (s.issuer.assets() > _balance) _fundIssuer(s.issuer.assets() - _balance);
    }

    function setExitCap(uint256 _mode, uint256 _cap) external {
        _mode = bound(_mode, 0, EXIT_CAP_MODES - 1);
        if (_mode == 0) s.issuer.setExitCap(0);
        else if (_mode == 1) s.issuer.setExitCap(bound(_cap, 1, MAX_EXIT_CAP_UNITS * s.quoteUnit));
        else s.issuer.setExitCap(type(uint256).max);
    }

    function setPaused(bool _paused) external {
        s.issuer.setPaused(_paused);
    }

    function addLiquidity(uint256 _liquidity) external {
        _liquidity = bound(_liquidity, s.liquidityUnit, MAX_LIQUIDITY_UNITS * s.liquidityUnit);
        try s.modifyLiquidityRouter.modifyLiquidity{value: quoteIsNative ? NATIVE_CALL_VALUE : 0}(
            s.poolKey, _fullRange(int256(_liquidity)), ""
        ) {
            liquidityAdded += _liquidity;
        } catch {}
    }

    function removeLiquidity(uint256 _liquidity) external {
        if (liquidityAdded == 0) return;
        _liquidity = bound(_liquidity, 1, liquidityAdded);
        try s.modifyLiquidityRouter.modifyLiquidity(s.poolKey, _fullRange(-int256(_liquidity)), "") {
            liquidityAdded -= _liquidity;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                                 CHECKS
    //////////////////////////////////////////////////////////////*/

    /// @dev §8.2: a direct fill never prices a buy below the ceiling or a sell above the floor.
    function _checkLogs() internal {
        Vm.Log[] memory _logs = vm.getRecordedLogs();
        for (uint256 _i; _i < _logs.length; ++_i) {
            if (_logs[_i].emitter != address(s.hook)) continue;
            if (_logs[_i].topics[0] == IMintToLiquidityHook.Rebalanced.selector) rebalances++;
            if (_logs[_i].topics[0] != IMintToLiquidityHook.DirectFilled.selector) continue;

            directFills++;
            (bool _isBuy, uint256 _tokens, uint256 _quote, uint256 _price) =
                abi.decode(_logs[_i].data, (bool, uint256, uint256, uint256));
            if (_isBuy ? _quote * WAD < _tokens * _price : _quote * WAD > _tokens * _price) fillPriceViolations++;
        }
    }

    /// @dev §8.7 and §8.3: hook trades never lower the redemption price or cost the beneficiary.
    function _checkAfterHookTrade(uint256 _redeemPriceBefore) internal {
        if (s.issuer.nav() < _redeemPriceBefore) redeemPriceDrops++;

        uint256 _beneficiaryQuote = quoteCurrency.balanceOf(s.beneficiary);
        if (_beneficiaryQuote < lastBeneficiaryQuote) beneficiaryLosses++;
        lastBeneficiaryQuote = _beneficiaryQuote;
    }

    function _lastRebalanceTokens() internal returns (bool _found, uint256 _tokens) {
        Vm.Log[] memory _logs = vm.getRecordedLogs();
        for (uint256 _i = _logs.length; _i > 0; --_i) {
            if (_logs[_i - 1].topics[0] == IMintToLiquidityHook.Rebalanced.selector) {
                (, _tokens,,) = abi.decode(_logs[_i - 1].data, (bool, uint256, uint256, uint256));
                return (true, _tokens);
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _settings() internal pure returns (PoolSwapTest.TestSettings memory) {
        return PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false});
    }

    function _fundIssuer(uint256 _amount) internal {
        if (quoteIsNative) vm.deal(address(s.issuer), address(s.issuer).balance + _amount);
        else s.quoteToken.mint(address(s.issuer), _amount);
    }

    function _sqrtPrice() internal view returns (uint160 _sqrtPriceX96) {
        (_sqrtPriceX96,,,) = s.manager.getSlot0(poolId);
    }

    function _fullRange(int256 _liquidityDelta) internal pure returns (ModifyLiquidityParams memory) {
        return ModifyLiquidityParams({
            tickLower: TickMath.minUsableTick(TICK_SPACING),
            tickUpper: TickMath.maxUsableTick(TICK_SPACING),
            liquidityDelta: _liquidityDelta,
            salt: bytes32(0)
        });
    }
}
