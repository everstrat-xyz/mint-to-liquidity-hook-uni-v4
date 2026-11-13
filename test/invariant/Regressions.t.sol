// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HandlerFixture} from "./HandlerFixture.sol";

abstract contract NativeQuoteRegressionTest is HandlerFixture {
    function _quoteIsNative() internal pure override returns (bool) {
        return true;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

abstract contract TokenIsCurrency0RegressionTest is HandlerFixture {
    function _quoteIsNative() internal pure override returns (bool) {
        return false;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return true;
    }
}

/**
 * @notice Call sequences the invariant campaign found, kept as plain tests.
 * @dev The arguments are the raw fuzzer inputs; the handler bounds them.
 */
contract DustLiquidityFromAboveRegressionTest is TokenIsCurrency0RegressionTest {
    /// A rebalance from above through dust liquidity was paid a few base units of quote for zero
    /// tokens. The hook left that credit untaken, and the PoolManager rejected the user's swap with
    /// `CurrencyNotSettled`.
    function test_Regression_DustLiquidity_RebalanceFromAbove() public {
        handler.addLiquidity(3473);
        handler.sell(2707, true);
        handler.driftNav(15762);
        handler.removeLiquidity(type(uint256).max - 2);
        handler.buy(12604036081875986601886376170439773486285280457072192335940894, true);

        assertEq(handler.swapReverts(), 0);
        _assertHookHoldsNothing();
    }
}

contract DustLiquidityFromBelowRegressionTest is NativeQuoteRegressionTest {
    /// The same through the floor: a rebalance from below was charged quote for zero tokens.
    function test_Regression_DustLiquidity_RebalanceFromBelow() public {
        handler.addLiquidity(1);
        handler.setPaused(true);
        handler.sell(64, true);
        handler.setExitCap(10000000, 64);
        handler.setPaused(false);
        handler.rebalance();
        handler.setExitCap(32, 9999000000000000009229);
        handler.driftNav(2000000000000000000);
        handler.sell(33331699646803944875197329075677, true);

        assertEq(handler.swapReverts(), 0);
        _assertHookHoldsNothing();
    }
}

contract ExactOutputBeyondDepthRegressionTest is NativeQuoteRegressionTest {
    /// Not a hook failure: the pool sat below the floor, the hook bought it back up to the floor
    /// before the swap, and the exact-output buy then asked for more tokens than the pool held.
    /// v4 reverts such an order on any pool. The handler must not count it against §8.6.
    function test_Regression_ExactOutputBeyondPoolDepth_NotCounted() public {
        handler.addLiquidity(1944);
        handler.setExitCap(1000, 489);
        handler.sell(389727823089521170021478212532802765678513750016, true);
        handler.sell(60, true);
        handler.addLiquidity(900000000000000000000000);
        handler.addLiquidity(6793);
        handler.addLiquidity(1662);
        handler.setExitCap(8033, 100000000000000000000000);
        handler.addLiquidity(17534);
        handler.removeLiquidity(1000000000000000000000000);
        handler.buy(16872, false);

        assertEq(handler.swapReverts(), 0);
        _assertHookHoldsNothing();
    }
}
