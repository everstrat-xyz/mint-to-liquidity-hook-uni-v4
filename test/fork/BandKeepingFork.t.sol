// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

import {ForkFixture} from "./ForkFixture.sol";

/**
 * @notice Band keeping against the deployed Everstrat AMM: a pool with LP liquidity, pushed past
 * either edge, pulled back by the hook through real mints and redemptions.
 */
contract BandKeepingForkTest is ForkFixture {
    using StateLibrary for IPoolManager;

    uint256 internal constant Q192 = 1 << 192;

    /// @dev Sized against Everstrat's ~5.6 ETH NAV: large enough to matter, small enough that the
    /// band does not jump out from under the pool.
    uint256 internal constant AMM_EXIT_LIQUIDITY = 0.3 ether;
    /// @dev Enough for the LP's side and the pushes below; raises NAV per EVE by about 1.5%.
    uint256 internal constant EVE_PURCHASE_ETH = 1 ether;
    uint256 internal constant LP_ETH = 0.4 ether;
    /// @dev Pushes the price well past an edge of a pool holding `LP_ETH` a side.
    uint256 internal constant PUSH_BUY_ETH = 0.3 ether;
    uint256 internal constant PUSH_SELL_DIVISOR = 2; // sell half the LP's EVE depth
    uint256 internal constant SMALL_BUY_ETH = 0.001 ether;
    uint256 internal constant ROUND_TRIPS = 4;

    uint256 internal lpEve;

    function setUp() public override {
        super.setUp();
        if (!forkAvailable) return;

        // Exit liquidity first: it raises NAV, and the pool should open at the band it will trade in.
        _fundAMMExits(AMM_EXIT_LIQUIDITY);
        _deployWithScript();
        _whitelistAdapter();

        // Get EVE the way any user would on day one: buy it from the empty pool, i.e. mint it.
        _buy(EVE_PURCHASE_ETH);

        // Seed full-range liquidity at the pool price.
        lpEve = FullMath.mulDiv(LP_ETH, uint256(_sqrtPrice()) * _sqrtPrice(), Q192);
        _addFullRangeLiquidity(LP_ETH, lpEve);
        require(!_isAboveCeiling() && !_isBelowFloor(), "setup: pool must start inside the band");
    }

    /*//////////////////////////////////////////////////////////////
                            INSIDE THE BAND
    //////////////////////////////////////////////////////////////*/

    function test_Fork_SmallBuyInsideBand_IssuerUntouched() public onlyFork {
        uint256 _supplyBefore = eve.totalSupply();

        vm.recordLogs();
        uint256 _bought = _buy(SMALL_BUY_ETH);

        Vm.Log[] memory _logs = vm.getRecordedLogs();
        assertGt(_bought, 0, "the curve filled it");
        assertEq(_countHookEvents(_logs, IMintToLiquidityHook.DirectFilled.selector), 0);
        assertEq(_countHookEvents(_logs, IMintToLiquidityHook.Rebalanced.selector), 0);
        assertEq(eve.totalSupply(), _supplyBefore, "no mint");
        assertEq(address(beneficiary).balance, 0, "no profit to take");
    }

    /*//////////////////////////////////////////////////////////////
                             ABOVE THE CEILING
    //////////////////////////////////////////////////////////////*/

    function test_Fork_BuyPastCeiling_HookMintsAndSellsBack() public onlyFork {
        uint256 _basePriceBefore = amm.eveBasePriceInETH();
        uint256 _supplyBefore = eve.totalSupply();

        vm.recordLogs();
        _buy(PUSH_BUY_ETH);

        (bool _found, bool _fromAbove, uint256 _tokens,, uint256 _profit) = _lastRebalance(vm.getRecordedLogs());
        assertTrue(_found && _fromAbove, "rebalanced from above");
        assertGt(_tokens, 0, "the hook minted");
        // The AMM mints `floor(eth / price)`, a hair more than the hook sold back; the rest is dust.
        uint256 _minted = eve.totalSupply() - _supplyBefore;
        assertGe(_minted, _tokens, "minted at least what it sold back");
        assertEq(eve.balanceOf(beneficiary), _minted - _tokens, "the dust went to the beneficiary");
        assertEq(address(beneficiary).balance, _profit, "profit went to the beneficiary");
        assertGt(_profit, 0);

        // Back under the ceiling, even though its own mint at a premium raised the ceiling.
        assertFalse(_isAboveCeiling(), "price above the ceiling");
        assertGe(amm.eveBasePriceInETH(), _basePriceBefore, "NAV per EVE fell");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_KeeperRebalance_AfterIssuerPause() public onlyFork {
        // The AMM is paused while a buyer pushes the price past the ceiling: the hook cannot mint,
        // so it stands aside and the swap goes through.
        _pauseAMM();
        vm.recordLogs();
        _buy(PUSH_BUY_ETH);
        assertEq(_countHookEvents(vm.getRecordedLogs(), IMintToLiquidityHook.RebalanceSkipped.selector), 1);
        assertTrue(_isAboveCeiling(), "left above the ceiling");

        // Once the timelock unpauses, anyone can pull the price back and the profit still goes to
        // the beneficiary, not to the caller.
        _unpauseAMM();
        uint256 _strangerBalance = stranger.balance;
        vm.prank(stranger);
        assertTrue(hook.rebalance(poolKey));

        assertFalse(_isAboveCeiling());
        assertGt(address(beneficiary).balance, 0);
        assertEq(stranger.balance, _strangerBalance, "the keeper earns nothing");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_BuyPastCeiling_AdapterRemovedFromWhitelist() public onlyFork {
        if (whitelist.disabled()) {
            vm.skip(true); // nothing to remove the adapter from
            return;
        }
        _removeAdapterFromWhitelist();

        vm.recordLogs();
        uint256 _bought = _buy(PUSH_BUY_ETH);

        // The AMM refuses the mint; the swap still fills on the curve.
        assertGt(_bought, 0);
        assertEq(_countHookEvents(vm.getRecordedLogs(), IMintToLiquidityHook.RebalanceSkipped.selector), 1);
        assertTrue(_isAboveCeiling());
        _assertHookAndAdapterHoldNothing();
    }

    /*//////////////////////////////////////////////////////////////
                              BELOW THE FLOOR
    //////////////////////////////////////////////////////////////*/

    function test_Fork_SellPastFloor_HookBuysAndRedeems() public onlyFork {
        uint256 _basePriceBefore = amm.eveBasePriceInETH();
        uint256 _supplyBefore = eve.totalSupply();
        uint256 _queuedBefore = eve.balanceOf(address(amm));

        vm.recordLogs();
        _sell(lpEve / PUSH_SELL_DIVISOR);

        (bool _found, bool _fromAbove, uint256 _tokens,, uint256 _profit) = _lastRebalance(vm.getRecordedLogs());
        assertTrue(_found && !_fromAbove, "rebalanced from below");
        assertGt(_tokens, 0, "the hook redeemed");
        assertLt(eve.totalSupply(), _supplyBefore, "EVE was burned");
        assertEq(eve.balanceOf(address(amm)), _queuedBefore, "no queued exit");
        assertEq(address(beneficiary).balance, _profit, "profit went to the beneficiary");
        assertGt(_profit, 0);

        // Back at the floor, or as close as the AMM's free ETH allowed.
        assertTrue(!_isBelowFloor() || amm.freeBalance() <= hook.ROUNDING_SLACK(), "below the floor with ETH left");
        assertGe(amm.eveBasePriceInETH(), _basePriceBefore, "NAV per EVE fell");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_SellPastFloor_NoFreeETH_FloorIsSoft() public onlyFork {
        vm.deal(address(amm), address(amm).balance - amm.freeBalance());
        uint256 _supplyBefore = eve.totalSupply();

        vm.recordLogs();
        uint256 _proceeds = _sell(lpEve / PUSH_SELL_DIVISOR);

        // Nothing to redeem with: the hook stands aside, the seller still gets the curve price.
        assertGt(_proceeds, 0);
        assertEq(_countHookEvents(vm.getRecordedLogs(), IMintToLiquidityHook.Rebalanced.selector), 0);
        assertTrue(_isBelowFloor(), "the floor is soft without exit liquidity");
        assertEq(eve.totalSupply(), _supplyBefore);
        _assertHookAndAdapterHoldNothing();
    }

    /*//////////////////////////////////////////////////////////////
                              ROUND TRIPS
    //////////////////////////////////////////////////////////////*/

    function test_Fork_RoundTrips_KeepTheInvariants() public onlyFork {
        uint256 _basePrice = amm.eveBasePriceInETH();
        uint256 _profit;

        for (uint256 _i; _i < ROUND_TRIPS; ++_i) {
            uint256 _bought = _buy(PUSH_BUY_ETH);
            _checkRound(_basePrice, _profit);
            (_basePrice, _profit) = (amm.eveBasePriceInETH(), address(beneficiary).balance);

            _sell(_bought);
            _checkRound(_basePrice, _profit);
            (_basePrice, _profit) = (amm.eveBasePriceInETH(), address(beneficiary).balance);
        }
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev README §8 on a live protocol: NAV per EVE and the beneficiary never lose, the hook holds nothing.
    function _checkRound(uint256 _basePriceBefore, uint256 _profitBefore) internal view {
        assertGe(amm.eveBasePriceInETH(), _basePriceBefore, "NAV per EVE fell");
        assertGe(address(beneficiary).balance, _profitBefore, "the beneficiary lost");
        assertFalse(_isAboveCeiling(), "left above the ceiling");
        _assertHookAndAdapterHoldNothing();
    }

    function _lastRebalance(Vm.Log[] memory _logs)
        internal
        view
        returns (bool _found, bool _fromAbove, uint256 _tokens, uint256 _quote, uint256 _profit)
    {
        for (uint256 _i = _logs.length; _i > 0; --_i) {
            Vm.Log memory _log = _logs[_i - 1];
            if (_log.emitter == address(hook) && _log.topics[0] == IMintToLiquidityHook.Rebalanced.selector) {
                (_fromAbove, _tokens, _quote, _profit) = abi.decode(_log.data, (bool, uint256, uint256, uint256));
                return (true, _fromAbove, _tokens, _quote, _profit);
            }
        }
    }
}
