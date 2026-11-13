// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {HandlerFixture} from "./HandlerFixture.sol";

/**
 * @notice The README §8 invariants, held across random sequences of swaps, NAV drift, issuer pauses,
 * exit-capacity changes, liquidity changes and public rebalances.
 */
abstract contract MintToLiquidityHookInvariantTest is HandlerFixture {
    function setUp() public override {
        super.setUp();
        targetContract(address(handler));
    }

    /// §8.1 After a rebalance that ran, the price is inside the band or at the exit-capacity limit.
    function invariant_RebalanceEndsInsideBand() public view {
        assertEq(handler.rebalanceBandViolations(), 0);
    }

    /// §8.2 A direct fill never prices a buy below the ceiling or a sell above the floor.
    function invariant_DirectFillsPricedAtTheEdges() public view {
        assertEq(handler.fillPriceViolations(), 0);
    }

    /// §8.3 The hook's trades never cost the beneficiary anything.
    function invariant_BeneficiaryNeverLoses() public view {
        assertEq(handler.beneficiaryLosses(), 0);
    }

    /// §8.4 The hook holds no quote or tokens between transactions.
    function invariant_HookHoldsNothing() public view {
        _assertHookHoldsNothing();
    }

    /// §8.5 The hook never causes a queued exit.
    function invariant_NoQueuedExit() public view {
        assertEq(issuer.overCapacityRedemptions(), 0);
    }

    /// §8.6 No user swap reverts because of the hook.
    function invariant_SwapsNeverRevert() public view {
        assertEq(handler.swapReverts(), 0, string(handler.lastSwapRevert()));
    }

    /// §8.7 The issuer's redemption price never falls as a result of a hook trade.
    function invariant_RedeemPriceNeverFalls() public view {
        assertEq(handler.redeemPriceDrops(), 0);
    }
}

contract MintToLiquidityHookNativeQuoteInvariantTest is MintToLiquidityHookInvariantTest {
    function _quoteIsNative() internal pure override returns (bool) {
        return true;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return false;
    }
}

contract MintToLiquidityHookTokenIsCurrency0InvariantTest is MintToLiquidityHookInvariantTest {
    function _quoteIsNative() internal pure override returns (bool) {
        return false;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return true;
    }
}
