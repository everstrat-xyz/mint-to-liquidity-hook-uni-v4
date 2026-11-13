// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/base/BaseHook.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Vm} from "forge-std/Vm.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IIssuerAdapter} from "interfaces/IIssuerAdapter.sol";
import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

import {MockIssuer} from "../mocks/MockIssuer.sol";
import {HookFixture} from "../utils/HookFixture.sol";

/**
 * @notice Unit tests of the hook. Abstract: the concrete contracts at the bottom of the file run it
 * with native ETH and with an ERC-20 quote on either side of the pool.
 */
abstract contract MintToLiquidityHookTest is HookFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant BUY_QUOTE_UNITS = 10;
    uint256 internal constant TRADE_TOKENS = 5e18;
    /// @dev Big enough to push a pool holding the default liquidity past either band edge.
    uint256 internal constant LARGE_BUY_QUOTE_UNITS = 2_000;
    uint256 internal constant LARGE_SELL_TOKENS = 1_000e18;
    uint256 internal constant SMALL_BUY_QUOTE_UNITS = 1;
    uint256 internal constant SMALL_SELL_TOKENS = 1e18;

    uint256 internal constant NAV_DROP = 0.85e18; // NAV falls 15%: the pool is left above the ceiling
    uint256 internal constant NAV_RISE = 1.15e18; // NAV rises 15%: the pool is left below the floor
    /// @dev How far above the ceiling the pool sits when the gap is smaller than the 0.3% LP fee.
    uint256 internal constant WITHIN_FEE_GAP = 1.001e18;
    uint256 internal constant SMALL_EXIT_CAP_UNITS = 3;

    address internal stranger = makeAddr("stranger");

    /*//////////////////////////////////////////////////////////////
                              REGISTRATION
    //////////////////////////////////////////////////////////////*/

    function test_RegisterPool() public view {
        IMintToLiquidityHook.PoolConfig memory _config = hook.poolConfig(poolId);
        IMintToLiquidityHook.Band memory _currentBand = _band();

        assertEq(address(_config.adapter), address(issuer));
        assertEq(_config.tokenIsCurrency0, tokenIsCurrency0);
        assertEq(address(poolKey.hooks), address(hook));
        assertEq(poolKey.fee, POOL_FEE);

        // The pool starts at the band's midpoint, strictly inside the band.
        assertEq(_sqrtPrice(), BandMath.midSqrtPriceX96(_currentBand, tokenIsCurrency0));
        assertFalse(BandMath.isAboveCeiling(_sqrtPrice(), _currentBand, tokenIsCurrency0));
        assertFalse(BandMath.isBelowFloor(_sqrtPrice(), _currentBand, tokenIsCurrency0));
        assertEq(manager.getLiquidity(poolId), 0);
    }

    function test_RegisterPool_EmitsEvent() public {
        IMintToLiquidityHook.Band memory _currentBand = _band();

        vm.expectEmit(false, true, false, true, address(hook));
        emit IMintToLiquidityHook.PoolRegistered(
            poolId, issuer, tokenIsCurrency0, BandMath.midSqrtPriceX96(_currentBand, tokenIsCurrency0)
        );
        vm.prank(issuerOwner);
        hook.registerPool(issuer, POOL_FEE + 1, TICK_SPACING);
    }

    function test_RegisterPool_AccessControl() public {
        vm.prank(stranger);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookNotAdapterOwner.selector);
        hook.registerPool(issuer, POOL_FEE + 1, TICK_SPACING);
    }

    function test_RegisterPool_InvalidInputs() public {
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookZeroAddress.selector);
        hook.registerPool(IIssuerAdapter(address(0)), POOL_FEE, TICK_SPACING);

        vm.startPrank(issuerOwner);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookDynamicFeeNotSupported.selector);
        hook.registerPool(issuer, LPFeeLibrary.DYNAMIC_FEE_FLAG, TICK_SPACING);
        vm.stopPrank();
    }

    function test_RegisterPool_InvalidConditions() public {
        vm.startPrank(issuerOwner);

        // The same adapter, fee and tick spacing make the same pool.
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookPoolAlreadyRegistered.selector);
        hook.registerPool(issuer, POOL_FEE, TICK_SPACING);

        // Redemption price above mint price.
        issuer.forcePrices(WAD, 2 * WAD);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookInvalidBand.selector);
        hook.registerPool(issuer, POOL_FEE + 1, TICK_SPACING);

        vm.stopPrank();
    }

    function test_RegisterPool_TokenEqualsQuote() public {
        MockIssuer _broken = new MockIssuer(token, tokenCurrency, issuerOwner, beneficiary, MINT_PREMIUM);

        vm.prank(issuerOwner);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookInvalidCurrencies.selector);
        hook.registerPool(_broken, POOL_FEE, TICK_SPACING);
    }

    function test_BeforeInitialize_UnregisteredPool() public {
        PoolKey memory _key = _unregisteredKey();
        uint160 _sqrtPriceX96 = _sqrtPrice();

        // The PoolManager wraps the hook's `MintToLiquidityHookPoolNotRegistered`.
        vm.expectRevert();
        manager.initialize(_key, _sqrtPriceX96);
    }

    function test_GetBand_UnregisteredPool() public {
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookPoolNotRegistered.selector);
        hook.getBand(_unregisteredKey().toId());
    }

    /*//////////////////////////////////////////////////////////////
                    DIRECT FILLS WITH NO LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_Swap_BuyExactInput_NoLiquidity() public {
        uint256 _quoteIn = BUY_QUOTE_UNITS * _quoteUnit();
        uint256 _ceiling = issuer.mintPrice();
        uint256 _expectedTokens = BandMath.tokensForQuoteDown(_quoteIn, _ceiling);
        uint256 _assetsBefore = issuer.assets();
        uint160 _sqrtPriceBefore = _sqrtPrice();

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.DirectFilled(poolId, true, _expectedTokens, _quoteIn, _ceiling);
        (uint256 _tokens, uint256 _quote) = _swap(true, true, _quoteIn);

        assertEq(_tokens, _expectedTokens, "tokens out");
        assertEq(_quote, _quoteIn, "quote in");
        assertEq(issuer.assets(), _assetsBefore + _quoteIn, "issuer received the quote");
        assertEq(_sqrtPrice(), _sqrtPriceBefore, "pool price untouched");
        _assertHookHoldsNothing();
    }

    function test_Swap_BuyExactOutput_NoLiquidity() public {
        uint256 _ceiling = issuer.mintPrice();
        uint256 _expectedQuote = BandMath.quoteForTokensUp(TRADE_TOKENS, _ceiling);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.DirectFilled(poolId, true, TRADE_TOKENS, _expectedQuote, _ceiling);
        (uint256 _tokens, uint256 _quote) = _swap(true, false, TRADE_TOKENS);

        assertEq(_tokens, TRADE_TOKENS, "tokens out");
        assertEq(_quote, _expectedQuote, "quote in");
        // The buyer never pays less than the ceiling.
        assertGe(_quote * WAD, _tokens * _ceiling, "priced below the ceiling");
        // Whatever the issuer minted beyond the exact output is the beneficiary's.
        assertEq(
            token.balanceOf(beneficiary), BandMath.tokensForQuoteDown(_expectedQuote, _ceiling) - TRADE_TOKENS, "dust"
        );
        _assertHookHoldsNothing();
    }

    function test_Swap_SellExactInput_NoLiquidity() public {
        uint256 _floor = issuer.redeemPrice();
        uint256 _expectedQuote = BandMath.quoteForTokensDown(TRADE_TOKENS, _floor) - hook.ROUNDING_SLACK();
        uint256 _supplyBefore = token.totalSupply();

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.DirectFilled(poolId, false, TRADE_TOKENS, _expectedQuote, _floor);
        (uint256 _tokens, uint256 _quote) = _swap(false, true, TRADE_TOKENS);

        assertEq(_tokens, TRADE_TOKENS, "tokens in");
        assertEq(_quote, _expectedQuote, "quote out");
        assertEq(token.totalSupply(), _supplyBefore - TRADE_TOKENS, "tokens were redeemed");
        // An issuer that rounds once leaves the slack with the beneficiary.
        assertEq(_quoteBalance(beneficiary), hook.ROUNDING_SLACK(), "slack");
        _assertHookHoldsNothing();
    }

    function test_Swap_SellExactOutput_NoLiquidity() public {
        uint256 _quoteOut = BUY_QUOTE_UNITS * _quoteUnit();
        uint256 _floor = issuer.redeemPrice();
        uint256 _expectedTokens = BandMath.tokensForQuoteUp(_quoteOut + hook.ROUNDING_SLACK(), _floor);

        (uint256 _tokens, uint256 _quote) = _swap(false, false, _quoteOut);

        assertEq(_quote, _quoteOut, "quote out");
        assertEq(_tokens, _expectedTokens, "tokens in");
        // The seller never receives more than the floor.
        assertLe(_quote * WAD, _tokens * _floor, "priced above the floor");
        _assertHookHoldsNothing();
    }

    function test_Swap_Sell_IssuerRoundsTwice() public {
        // The issuer pays one base unit less than `tokens * floor`, as the Everstrat AMM does.
        issuer.setRedeemShortfall(hook.ROUNDING_SLACK());
        uint256 _floor = issuer.redeemPrice();
        uint256 _quoteOut = BUY_QUOTE_UNITS * _quoteUnit();

        (uint256 _tokens, uint256 _quote) = _swap(false, true, TRADE_TOKENS);
        assertEq(_tokens, TRADE_TOKENS, "exact input: tokens in");
        assertEq(_quote, BandMath.quoteForTokensDown(TRADE_TOKENS, _floor) - hook.ROUNDING_SLACK(), "exact input");

        (, _quote) = _swap(false, false, _quoteOut);
        assertEq(_quote, _quoteOut, "exact output: quote out");

        // Sizing an exact output rounds the tokens up, which can leave a base unit over.
        assertLe(_quoteBalance(beneficiary), hook.ROUNDING_SLACK(), "at most a base unit left over");
        _assertHookHoldsNothing();
    }

    function test_Swap_Sell_CappedByExitCapacity() public {
        uint256 _cap = SMALL_EXIT_CAP_UNITS * _quoteUnit();
        issuer.setExitCap(_cap);
        uint256 _floor = issuer.redeemPrice();

        // Worth more than the cap: the hook redeems what the issuer can pay and no more.
        (uint256 _tokens, uint256 _quote) = _swap(false, true, TRADE_TOKENS);

        assertEq(_quote, _cap - hook.ROUNDING_SLACK(), "quote out is the capacity");
        assertEq(_tokens, BandMath.tokensForQuoteUp(_cap, _floor), "tokens in match the capacity");
        assertLt(_tokens, TRADE_TOKENS, "the rest found no liquidity");
        assertEq(issuer.overCapacityRedemptions(), 0, "no queued exit");
        _assertHookHoldsNothing();
    }

    function testFuzz_Swap_Sell_FilledAtAnyExitCapacity(uint256 _cap, bool _exactInput) public {
        // Any capacity worth at least a base unit more than the slack, and less than the sell.
        uint256 _floor = issuer.redeemPrice();
        uint256 _sellValue = BandMath.quoteForTokensDown(TRADE_TOKENS, _floor);
        _cap = bound(_cap, 2 * hook.ROUNDING_SLACK() + 2, _sellValue - 1);
        issuer.setExitCap(_cap);

        vm.recordLogs();
        (uint256 _tokens, uint256 _quote) =
            _exactInput ? _swap(false, true, TRADE_TOKENS) : _swap(false, false, _sellValue);

        // The capped fill happens, never pays more than the issuer can, and never queues.
        assertGt(_tokens, 0, "filled");
        assertLe(_quote, _cap, "paid within the capacity");
        assertEq(issuer.overCapacityRedemptions(), 0, "no queued exit");
        assertEq(_countFills(vm.getRecordedLogs()), 1);
        _assertHookHoldsNothing();
    }

    function test_Swap_Sell_NoExitCapacity() public {
        issuer.setExitCap(0);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.DirectFillSkipped(
            poolId, abi.encodeWithSelector(IMintToLiquidityHook.MintToLiquidityHookNothingToFill.selector)
        );
        (uint256 _tokens, uint256 _quote) = _swap(false, true, TRADE_TOKENS);

        // A token with no redemption gets a ceiling only: the sell finds nothing and does not revert.
        assertEq(_tokens, 0);
        assertEq(_quote, 0);
        _assertHookHoldsNothing();
    }

    function test_Swap_Sell_CappedByManagerReserves() public {
        // The hook can only take tokens the PoolManager already holds.
        uint256 _amount = MANAGER_TOKEN_RESERVE + TRADE_TOKENS;

        (uint256 _tokens,) = _swap(false, true, _amount);

        assertEq(_tokens, MANAGER_TOKEN_RESERVE, "filled up to the reserves");
        _assertHookHoldsNothing();
    }

    function test_Swap_Buy_CappedByManagerReserves() public {
        uint256 _reserve = _quoteBalance(address(manager));
        uint256 _ceiling = issuer.mintPrice();

        (uint256 _tokens, uint256 _quote) = _swap(true, true, _reserve + _quoteUnit());

        assertEq(_quote, _reserve, "filled up to the reserves");
        assertEq(_tokens, BandMath.tokensForQuoteDown(_reserve, _ceiling));
        _assertHookHoldsNothing();
    }

    function test_Swap_Buy_WhenIssuerPaused() public {
        issuer.setPaused(true);
        uint256 _assetsBefore = issuer.assets();

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.DirectFillSkipped(
            poolId, abi.encodeWithSelector(MockIssuer.MockIssuerPaused.selector)
        );
        (uint256 _tokens, uint256 _quote) = _swap(true, true, BUY_QUOTE_UNITS * _quoteUnit());

        // The swap falls through to an empty curve instead of reverting.
        assertEq(_tokens, 0);
        assertEq(_quote, 0);
        assertEq(issuer.assets(), _assetsBefore);
        _assertHookHoldsNothing();
    }

    function test_Swap_Buy_PriceLimitInsideCeiling() public {
        // A limit at the current price does not allow a fill at the ceiling.
        uint160 _limit = tokenIsCurrency0 ? _sqrtPrice() + 1 : _sqrtPrice() - 1;
        uint256 _assetsBefore = issuer.assets();

        (uint256 _tokens,) = _swapWithLimit(true, true, BUY_QUOTE_UNITS * _quoteUnit(), _limit);

        assertEq(_tokens, 0, "not filled");
        assertEq(issuer.assets(), _assetsBefore);
    }

    function test_Swap_SinglePrice() public {
        // `redeemPrice() == 0`: one price for buys and sells, and the pool works as a converter.
        issuer.setSinglePrice(true);
        uint256 _price = issuer.mintPrice();
        assertEq(issuer.redeemPrice(), 0);
        uint256 _quoteIn = BUY_QUOTE_UNITS * _quoteUnit();

        (uint256 _bought,) = _swap(true, true, _quoteIn);
        assertEq(_bought, BandMath.tokensForQuoteDown(_quoteIn, _price), "buy at the single price");

        (, uint256 _proceeds) = _swap(false, true, _bought);
        assertEq(
            _proceeds, BandMath.quoteForTokensDown(_bought, _price) - hook.ROUNDING_SLACK(), "sell at the same price"
        );

        IMintToLiquidityHook.Band memory _currentBand = _band();
        assertEq(_currentBand.floor, _currentBand.ceiling, "band collapsed");
        assertEq(_sqrtPrice(), _currentBand.sqrtCeilingX96, "pool sits on the price");
        _assertHookHoldsNothing();
    }

    /*//////////////////////////////////////////////////////////////
                              INVALID BAND
    //////////////////////////////////////////////////////////////*/

    function test_Swap_InvalidBand() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        issuer.forcePrices(WAD, 2 * WAD);
        uint256 _assetsBefore = issuer.assets();

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.BandInvalidated(poolId, WAD, 2 * WAD);
        (uint256 _tokens,) = _swap(true, true, LARGE_BUY_QUOTE_UNITS * _quoteUnit());

        // The hook stands aside: the curve fills the swap and the issuer is never called.
        assertGt(_tokens, 0, "curve filled the swap");
        assertEq(issuer.assets(), _assetsBefore);
        assertEq(_quoteBalance(beneficiary), 0);
    }

    function test_Swap_BandUnreadable() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        vm.mockCallRevert(address(issuer), abi.encodeCall(IIssuerAdapter.mintPrice, ()), "");

        (uint256 _tokens,) = _swap(true, true, SMALL_BUY_QUOTE_UNITS * _quoteUnit());

        assertGt(_tokens, 0, "curve filled the swap");
    }

    /*//////////////////////////////////////////////////////////////
                          SWAPS WITH LIQUIDITY
    //////////////////////////////////////////////////////////////*/

    function test_Swap_InsideBand_UsesCurve() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        uint256 _assetsBefore = issuer.assets();
        uint256 _supplyBefore = token.totalSupply();
        uint160 _sqrtPriceBefore = _sqrtPrice();

        (uint256 _tokens,) = _swap(true, true, SMALL_BUY_QUOTE_UNITS * _quoteUnit());

        assertGt(_tokens, 0);
        assertTrue(_sqrtPrice() != _sqrtPriceBefore, "the curve moved");
        assertEq(issuer.assets(), _assetsBefore, "issuer untouched");
        assertEq(token.totalSupply(), _supplyBefore, "issuer untouched");
        assertEq(_quoteBalance(beneficiary), 0);
    }

    function test_Swap_BuyPushesPastCeiling_RebalancesAfter() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        IMintToLiquidityHook.Band memory _bandBefore = _band();
        uint256 _supplyBefore = token.totalSupply();

        vm.expectEmit(true, false, false, false, address(hook));
        emit IMintToLiquidityHook.Rebalanced(poolId, true, 0, 0, 0);
        _swap(true, true, LARGE_BUY_QUOTE_UNITS * _quoteUnit());

        // The hook minted at the ceiling and sold into the pool down to it.
        assertEq(_sqrtPrice(), _bandBefore.sqrtCeilingX96, "price back at the ceiling");
        assertGt(token.totalSupply(), _supplyBefore, "hook minted");
        assertGt(_quoteBalance(beneficiary), 0, "profit went to the beneficiary");
        assertFalse(BandMath.isAboveCeiling(_sqrtPrice(), _band(), tokenIsCurrency0));
        _assertHookHoldsNothing();
    }

    function test_Swap_SellPushesPastFloor_RebalancesAfter() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        IMintToLiquidityHook.Band memory _bandBefore = _band();
        uint256 _supplyBefore = token.totalSupply();

        vm.expectEmit(true, false, false, false, address(hook));
        emit IMintToLiquidityHook.Rebalanced(poolId, false, 0, 0, 0);
        _swap(false, true, LARGE_SELL_TOKENS);

        // The hook bought from the pool up to the floor and redeemed at it.
        assertEq(_sqrtPrice(), _bandBefore.sqrtFloorX96, "price back at the floor");
        assertLt(token.totalSupply(), _supplyBefore, "hook redeemed");
        assertGt(_quoteBalance(beneficiary), 0, "profit went to the beneficiary");
        assertEq(issuer.overCapacityRedemptions(), 0);
        _assertHookHoldsNothing();
    }

    function test_Swap_DriftAboveCeiling_RebalancesBefore() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_DROP);
        assertTrue(BandMath.isAboveCeiling(_sqrtPrice(), _band(), tokenIsCurrency0), "setup: above the ceiling");

        vm.expectEmit(true, false, false, false, address(hook));
        emit IMintToLiquidityHook.Rebalanced(poolId, true, 0, 0, 0);
        _swap(false, true, SMALL_SELL_TOKENS);

        assertFalse(BandMath.isAboveCeiling(_sqrtPrice(), _band(), tokenIsCurrency0), "back in the band");
        assertGt(_quoteBalance(beneficiary), 0, "profit went to the beneficiary");
        _assertHookHoldsNothing();
    }

    function test_Swap_DriftBelowFloor_RebalancesBefore() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_RISE);
        // The NAV gain is real: the issuer holds the quote to pay it out.
        _dealQuote(address(issuer), issuer.assets() - _quoteBalance(address(issuer)));
        assertTrue(BandMath.isBelowFloor(_sqrtPrice(), _band(), tokenIsCurrency0), "setup: below the floor");

        vm.expectEmit(true, false, false, false, address(hook));
        emit IMintToLiquidityHook.Rebalanced(poolId, false, 0, 0, 0);
        _swap(true, true, SMALL_BUY_QUOTE_UNITS * _quoteUnit());

        assertFalse(BandMath.isBelowFloor(_sqrtPrice(), _band(), tokenIsCurrency0), "back in the band");
        assertGt(_quoteBalance(beneficiary), 0, "profit went to the beneficiary");
        _assertHookHoldsNothing();
    }

    function test_Swap_AboveCeilingWithinFee_BuyFilledDirectly() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        // Leave the pool a hair above the ceiling: closer than the LP fee, so selling into it loses money.
        issuer.setNav((_poolPrice() * WAD / WITHIN_FEE_GAP) * WAD / (WAD + MINT_PREMIUM));
        assertTrue(BandMath.isAboveCeiling(_sqrtPrice(), _band(), tokenIsCurrency0), "setup: above the ceiling");

        uint256 _quoteIn = BUY_QUOTE_UNITS * _quoteUnit();
        uint256 _ceiling = issuer.mintPrice();

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.RebalanceSkipped(
            poolId, abi.encodeWithSelector(IMintToLiquidityHook.MintToLiquidityHookUnprofitableRebalance.selector)
        );
        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.DirectFilled(
            poolId, true, BandMath.tokensForQuoteDown(_quoteIn, _ceiling), _quoteIn, _ceiling
        );
        (uint256 _tokens,) = _swap(true, true, _quoteIn);

        // The buyer gets the mint price even though the pool quotes worse.
        assertEq(_tokens, BandMath.tokensForQuoteDown(_quoteIn, _ceiling));
        _assertHookHoldsNothing();
    }

    function test_Swap_WhenIssuerPaused_StillSwaps() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_DROP);
        issuer.setPaused(true);

        vm.expectEmit(true, false, false, true, address(hook));
        emit IMintToLiquidityHook.RebalanceSkipped(poolId, abi.encodeWithSelector(MockIssuer.MockIssuerPaused.selector));
        (, uint256 _quote) = _swap(false, true, SMALL_SELL_TOKENS);

        assertGt(_quote, 0, "curve filled the swap");
        assertTrue(BandMath.isAboveCeiling(_sqrtPrice(), _band(), tokenIsCurrency0), "price left where it was");
        _assertHookHoldsNothing();
    }

    function test_Swap_SellWithLimitBeforeCeiling_SkipsEarlyRebalance() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_DROP);
        // The seller's limit sits between the pool price and the ceiling. Rebalancing first would
        // carry the price past it and make v4 reject the swap, so the hook waits for `afterSwap`.
        uint160 _limit = tokenIsCurrency0 ? _sqrtPrice() - 1 : _sqrtPrice() + 1;

        _swapWithLimit(false, true, SMALL_SELL_TOKENS, _limit);

        assertFalse(BandMath.isAboveCeiling(_sqrtPrice(), _band(), tokenIsCurrency0), "rebalanced afterwards");
        assertGt(_quoteBalance(beneficiary), 0);
        _assertHookHoldsNothing();
    }

    /*//////////////////////////////////////////////////////////////
                            PUBLIC REBALANCE
    //////////////////////////////////////////////////////////////*/

    function test_Rebalance_InsideBand() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        uint160 _sqrtPriceBefore = _sqrtPrice();

        vm.prank(stranger);
        bool _ran = hook.rebalance(poolKey);

        assertFalse(_ran);
        assertEq(_sqrtPrice(), _sqrtPriceBefore);
    }

    function test_Rebalance_FromAbove() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_DROP);
        uint160 _sqrtCeilingX96 = _band().sqrtCeilingX96;
        uint256 _ceiling = issuer.mintPrice();

        vm.recordLogs();
        vm.prank(stranger);
        bool _ran = hook.rebalance(poolKey);

        assertTrue(_ran);
        assertEq(_sqrtPrice(), _sqrtCeilingX96, "price at the ceiling");
        // Every token was sold for at least what it cost to mint.
        (uint256 _tokens, uint256 _quote, uint256 _profit) = _lastRebalance();
        assertGe(_quote, BandMath.quoteForTokensUp(_tokens, _ceiling), "sold below the mint price");
        assertEq(_profit, _quoteBalance(beneficiary));
        assertEq(_profit, _quote - BandMath.quoteForTokensUp(_tokens, _ceiling));
        _assertHookHoldsNothing();
    }

    function test_Rebalance_FromBelow() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_RISE);
        _dealQuote(address(issuer), issuer.assets() - _quoteBalance(address(issuer)));
        uint160 _sqrtFloorX96 = _band().sqrtFloorX96;
        uint256 _floor = issuer.redeemPrice();

        vm.recordLogs();
        vm.prank(stranger);
        bool _ran = hook.rebalance(poolKey);

        assertTrue(_ran);
        assertEq(_sqrtPrice(), _sqrtFloorX96, "price at the floor");
        // Every token was bought for no more than it redeems for.
        (uint256 _tokens, uint256 _quote, uint256 _profit) = _lastRebalance();
        assertLe(_quote, BandMath.quoteForTokensDown(_tokens, _floor), "bought above the redemption price");
        assertEq(_profit, _quoteBalance(beneficiary));
        _assertHookHoldsNothing();
    }

    function test_Rebalance_FromBelow_CappedByExitCapacity() public {
        _addFullRangeLiquidity(_defaultLiquidity());
        _scaleNav(NAV_RISE);
        uint256 _cap = SMALL_EXIT_CAP_UNITS * _quoteUnit();
        issuer.setExitCap(_cap);
        uint256 _floor = issuer.redeemPrice();

        vm.recordLogs();
        hook.rebalance(poolKey);

        // The floor is soft beyond what the issuer can pay out now.
        (uint256 _tokens,,) = _lastRebalance();
        assertEq(_tokens, BandMath.tokensForQuoteDown(_cap, _floor), "bought what the capacity redeems");
        assertTrue(BandMath.isBelowFloor(_sqrtPrice(), _band(), tokenIsCurrency0), "still below the floor");
        assertEq(issuer.overCapacityRedemptions(), 0, "no queued exit");
        _assertHookHoldsNothing();
    }

    function test_Rebalance_NoLiquidity_MovesPriceForFree() public {
        _scaleNav(NAV_DROP);
        uint256 _assetsBefore = issuer.assets();
        uint160 _sqrtCeilingX96 = _band().sqrtCeilingX96;

        assertTrue(hook.rebalance(poolKey));

        assertEq(_sqrtPrice(), _sqrtCeilingX96);
        assertEq(issuer.assets(), _assetsBefore, "nothing to mint");
    }

    function test_Rebalance_InvalidConditions() public {
        _addFullRangeLiquidity(_defaultLiquidity());

        // Unregistered pool.
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookPoolNotRegistered.selector);
        hook.rebalance(_unregisteredKey());

        // Unlike a rebalance inside a swap, the public one reverts with the issuer.
        _scaleNav(NAV_DROP);
        issuer.setPaused(true);
        vm.expectRevert(MockIssuer.MockIssuerPaused.selector);
        hook.rebalance(poolKey);
        issuer.setPaused(false);

        // No exit capacity to buy with.
        _scaleNav(WAD * WAD / NAV_DROP * NAV_RISE / WAD);
        issuer.setExitCap(0);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookNoExitCapacity.selector);
        hook.rebalance(poolKey);
        issuer.setExitCap(type(uint256).max);

        // Invalid band.
        issuer.forcePrices(WAD, 2 * WAD);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookInvalidBand.selector);
        hook.rebalance(poolKey);
    }

    /*//////////////////////////////////////////////////////////////
                             ACCESS CONTROL
    //////////////////////////////////////////////////////////////*/

    function test_RebalanceInternal_AccessControl() public {
        vm.prank(stranger);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookCallerNotSelf.selector);
        hook.rebalanceInternal(poolKey);
    }

    function test_FillInternal_AccessControl() public {
        SwapParams memory _params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(TRADE_TOKENS), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        vm.prank(stranger);
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookCallerNotSelf.selector);
        hook.fillInternal(poolKey, _params);
    }

    function test_UnlockCallback_AccessControl() public {
        vm.prank(stranger);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(poolKey));
    }

    function test_HookCallbacks_AccessControl() public {
        SwapParams memory _params =
            SwapParams({zeroForOne: true, amountSpecified: -int256(TRADE_TOKENS), sqrtPriceLimitX96: MIN_PRICE_LIMIT});

        vm.startPrank(stranger);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(stranger, poolKey, _params, ZERO_BYTES);
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(stranger, poolKey, MIN_PRICE_LIMIT);
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _countFills(Vm.Log[] memory _logs) internal view returns (uint256 _count) {
        for (uint256 _i; _i < _logs.length; ++_i) {
            if (_logs[_i].emitter == address(hook) && _logs[_i].topics[0] == IMintToLiquidityHook.DirectFilled.selector)
            {
                _count++;
            }
        }
    }

    /// @dev Decodes the last `Rebalanced` event recorded since `vm.recordLogs()`.
    function _lastRebalance() internal returns (uint256 _tokens, uint256 _quote, uint256 _profit) {
        Vm.Log[] memory _logs = vm.getRecordedLogs();
        for (uint256 _i = _logs.length; _i > 0; --_i) {
            if (_logs[_i - 1].topics[0] == IMintToLiquidityHook.Rebalanced.selector) {
                (, _tokens, _quote, _profit) = abi.decode(_logs[_i - 1].data, (bool, uint256, uint256, uint256));
                return (_tokens, _quote, _profit);
            }
        }
        revert("no Rebalanced event");
    }
}

/// @notice Native ETH quote, as Everstrat uses. The token is always `currency1`.
contract MintToLiquidityHookNativeQuoteTest is MintToLiquidityHookTest {
    function _quoteIsNative() internal pure override returns (bool) {
        return true;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function test_Fixture_TokenIsCurrency1() public view {
        assertFalse(tokenIsCurrency0);
        assertTrue(poolKey.currency0.isAddressZero());
    }
}

/// @notice ERC-20 quote, token is `currency0`: sqrtPrice rises with the token's price.
contract MintToLiquidityHookTokenIsCurrency0Test is MintToLiquidityHookTest {
    function _quoteIsNative() internal pure override returns (bool) {
        return false;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function test_Fixture_TokenIsCurrency0() public view {
        assertTrue(tokenIsCurrency0);
    }
}

/// @notice ERC-20 quote, token is `currency1`: sqrtPrice falls as the token's price rises.
contract MintToLiquidityHookTokenIsCurrency1Test is MintToLiquidityHookTest {
    function _quoteIsNative() internal pure override returns (bool) {
        return false;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return false;
    }

    function test_Fixture_TokenIsCurrency1() public view {
        assertFalse(tokenIsCurrency0);
    }
}

/// @notice A 6-decimal quote against the 18-decimal token, as a USDC-quoted issuer would have.
contract MintToLiquidityHookSixDecimalQuoteTest is MintToLiquidityHookTest {
    uint8 internal constant USDC_DECIMALS = 6;

    function _quoteIsNative() internal pure override returns (bool) {
        return false;
    }

    function _wantTokenAsCurrency0() internal pure override returns (bool) {
        return true;
    }

    function _quoteDecimals() internal pure override returns (uint8) {
        return USDC_DECIMALS;
    }
}
