// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

import {ForkFixture} from "./ForkFixture.sol";

/**
 * @notice Direct fills against the deployed Everstrat AMM, in a pool with no liquidity at all: the
 * issuer is the whole market, as on day one.
 */
contract EverstratAMMAdapterForkTest is ForkFixture {
    uint256 internal constant BUY_ETH = 0.5 ether;
    /// @dev ETH given to the AMM so redemptions can be paid at once; live, its free balance is often zero.
    uint256 internal constant AMM_EXIT_LIQUIDITY = 0.5 ether;
    uint256 internal constant SELL_DIVISOR = 2; // sell half of what was bought
    /// @dev Worth roughly a quarter of the EVE a `BUY_ETH` purchase sells; deliberately not round.
    uint256 internal constant SMALL_EXIT_LIQUIDITY = 0.0123456789 ether;

    function setUp() public override {
        super.setUp();
        if (!forkAvailable) return;

        _deployWithScript();
    }

    function test_Fork_AdapterQuotesTheAMM() public onlyFork {
        assertEq(adapter.mintPrice(), amm.evePremiumPriceInETH());
        assertEq(adapter.redeemPrice(), amm.eveBasePriceInETH());
        assertEq(adapter.maxRedeemNow(), amm.freeBalance());
        assertGt(adapter.mintPrice(), adapter.redeemPrice(), "EVE mints at a premium over NAV");
    }

    function test_Fork_Buy_MintsThroughTheAMM() public onlyFork {
        _whitelistAdapter();
        uint256 _ceiling = amm.evePremiumPriceInETH();
        uint256 _floorBefore = amm.eveBasePriceInETH();
        uint256 _supplyBefore = eve.totalSupply();

        uint256 _bought = _buy(BUY_ETH);

        assertEq(_bought, BandMath.tokensForQuoteDown(BUY_ETH, _ceiling), "minted at the premium price");
        assertEq(eve.totalSupply(), _supplyBefore + _bought);
        assertGe(amm.eveBasePriceInETH(), _floorBefore, "minting at a premium does not lower NAV per EVE");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_Buy_AdapterNotWhitelisted() public onlyFork {
        if (whitelist.disabled()) {
            vm.skip(true); // the invite period is over: everyone may enter
            return;
        }
        uint256 _supplyBefore = eve.totalSupply();

        vm.recordLogs();
        uint256 _bought = _buy(BUY_ETH);

        // The AMM turns the adapter away; the swap finds an empty curve instead of reverting.
        assertEq(_bought, 0);
        assertEq(eve.totalSupply(), _supplyBefore);
        assertEq(_countHookEvents(vm.getRecordedLogs(), IMintToLiquidityHook.DirectFillSkipped.selector), 1);
    }

    function test_Fork_Buy_WhenAMMPaused() public onlyFork {
        _whitelistAdapter();
        _pauseAMM();
        uint256 _ethBefore = address(this).balance;

        uint256 _bought = _buy(BUY_ETH);

        assertEq(_bought, 0, "no market while the issuer is paused");
        // The router refunds the unused ETH (plus whatever dust its address already held on mainnet).
        assertGe(address(this).balance, _ethBefore, "the buyer keeps their ETH");
        // The empty curve dragged the price to the extreme tick; `afterSwap` put it back at the
        // ceiling, which needs no issuer call when there is no liquidity in the way.
        assertEq(_sqrtPrice(), _band().sqrtCeilingX96, "price back at the ceiling");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_Sell_RedeemsThroughTheAMM() public onlyFork {
        _whitelistAdapter();
        uint256 _bought = _buy(BUY_ETH);
        _fundAMMExits(AMM_EXIT_LIQUIDITY);
        // The hook can only take EVE the PoolManager already holds; this stands in for other pools.
        uint256 _amount = _bought / SELL_DIVISOR;
        eve.transfer(address(POOL_MANAGER), _amount);

        uint256 _floor = amm.eveBasePriceInETH();
        uint256 _supplyBefore = eve.totalSupply();

        uint256 _proceeds = _sell(_amount);

        assertEq(_proceeds, BandMath.quoteForTokensDown(_amount, _floor) - hook.ROUNDING_SLACK(), "paid at NAV");
        // The AMM burns `floor(eth / price)`, which leaves less than one wei's worth of EVE unburned.
        assertApproxEqAbs(eve.totalSupply(), _supplyBefore - _amount, WAD * WAD / _floor, "redeemed");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_Sell_CappedAtFreeETH() public onlyFork {
        _whitelistAdapter();
        uint256 _bought = _buy(BUY_ETH);
        uint256 _amount = _bought / SELL_DIVISOR;
        eve.transfer(address(POOL_MANAGER), _amount);
        // Leave the AMM free ETH well short of what the sell is worth, and not a round number.
        _drainAMMFreeBalance();
        _fundAMMExits(SMALL_EXIT_LIQUIDITY);
        uint256 _capacity = amm.freeBalance();
        assertLt(_capacity, BandMath.quoteForTokensDown(_amount, amm.eveBasePriceInETH()), "setup: capacity binds");

        vm.recordLogs();
        uint256 _proceeds = _sell(_amount);

        // The hook redeems what the AMM can pay now and leaves the rest; nothing is queued.
        assertEq(_countHookEvents(vm.getRecordedLogs(), IMintToLiquidityHook.DirectFilled.selector), 1, "filled");
        assertGt(_proceeds, 0, "filled up to the free balance");
        assertLe(_proceeds, _capacity, "never more than the free balance");
        assertEq(eve.balanceOf(address(amm)), 0, "no queued exit");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_Sell_NoFreeETH_NeverQueues() public onlyFork {
        _whitelistAdapter();
        uint256 _bought = _buy(BUY_ETH);
        uint256 _amount = _bought / SELL_DIVISOR;
        eve.transfer(address(POOL_MANAGER), _amount);
        _drainAMMFreeBalance();

        uint256 _supplyBefore = eve.totalSupply();
        uint256 _ammEveBefore = eve.balanceOf(address(amm));
        uint256 _holderEveBefore = eve.balanceOf(address(this));

        _sell(_amount);

        // Nothing was redeemed and nothing was escrowed in the exit queue.
        assertEq(eve.totalSupply(), _supplyBefore);
        assertEq(eve.balanceOf(address(amm)), _ammEveBefore, "no queued exit");
        assertEq(eve.balanceOf(address(this)), _holderEveBefore, "the sell found no market");
        _assertHookAndAdapterHoldNothing();
    }

    /// @dev The mint above sent its ETH on to the Controller; this removes whatever free ETH is left.
    function _drainAMMFreeBalance() internal {
        vm.deal(address(amm), address(amm).balance - amm.freeBalance());
    }
}
