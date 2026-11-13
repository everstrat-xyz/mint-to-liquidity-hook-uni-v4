// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Vm} from "forge-std/Vm.sol";

import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";

import {ForkFixture} from "./ForkFixture.sol";

/// @notice The Universal Router entry point (Uniswap `UniversalRouter`).
interface IUniversalRouter {
    function execute(bytes calldata _commands, bytes[] calldata _inputs, uint256 _deadline) external payable;
}

/// @notice Permit2 allowances, which the Universal Router pulls ERC-20 input through.
interface IPermit2 {
    function approve(address _token, address _spender, uint160 _amount, uint48 _expiration) external;
}

/**
 * @notice Swaps through the production Universal Router and v4 router actions, the path Uniswap's own
 * interface and most aggregators use, into a pool that has no liquidity at all.
 *
 * README §11 says direct sells need the token to be in the PoolManager already, because a router
 * pays the swapper's input after the swap. The v4 router lets the caller settle first instead, and
 * these tests show what that does: it turns an unfillable sell into a direct redemption.
 */
contract UniversalRouterForkTest is ForkFixture {
    IUniversalRouter internal constant UNIVERSAL_ROUTER = IUniversalRouter(0x66a9893cC07D91D95644AEDD05D03f95e1dBA8Af);
    IPermit2 internal constant PERMIT2 = IPermit2(0x000000000022D473030F116dDEE9F6B43aC78BA3);

    /// @dev Universal Router command and v4 router actions (`Commands.sol`, `Actions.sol`).
    uint8 internal constant V4_SWAP = 0x10;
    uint8 internal constant SWAP_EXACT_IN_SINGLE = 0x06;
    uint8 internal constant SETTLE = 0x0b;
    uint8 internal constant SETTLE_ALL = 0x0c;
    uint8 internal constant TAKE_ALL = 0x0f;

    uint256 internal constant BUY_ETH = 0.2 ether;
    uint256 internal constant AMM_EXIT_LIQUIDITY = 0.3 ether;
    uint256 internal constant SELL_DIVISOR = 2;
    uint256 internal constant DEADLINE_OFFSET = 1 hours;
    uint48 internal constant PERMIT_EXPIRATION_OFFSET = 1 hours;

    /// @dev Mirrors `IV4Router.ExactInputSingleParams`.
    struct ExactInputSingleParams {
        PoolKey poolKey;
        bool zeroForOne;
        uint128 amountIn;
        uint128 amountOutMinimum;
        bytes hookData;
    }

    function setUp() public override {
        super.setUp();
        if (!forkAvailable) return;

        _fundAMMExits(AMM_EXIT_LIQUIDITY);
        _deployWithScript();
        _whitelistAdapter();
    }

    function test_Fork_UniversalRouter_Buy() public onlyFork {
        uint256 _expected = BandMath.tokensForQuoteDown(BUY_ETH, amm.evePremiumPriceInETH());

        uint256 _bought = _routerBuy(BUY_ETH, _expected);

        // The slippage floor is the exact mint amount, and the router accepted it.
        assertEq(_bought, _expected, "minted at the premium price through the router");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_UniversalRouter_SellSettleFirst_FilledFromAnEmptyPool() public onlyFork {
        uint256 _amount = _routerBuy(BUY_ETH, 0) / SELL_DIVISOR;
        uint256 _managerEve = eve.balanceOf(address(POOL_MANAGER));
        uint256 _expected = BandMath.quoteForTokensDown(_amount, amm.eveBasePriceInETH()) - hook.ROUNDING_SLACK();

        // SETTLE pays the EVE into the PoolManager before the swap, so the hook can take it.
        vm.recordLogs();
        uint256 _proceeds = _routerSell(_amount, _expected, true);

        assertEq(_proceeds, _expected, "redeemed at NAV through the router");
        assertEq(_countHookEvents(vm.getRecordedLogs(), IMintToLiquidityHook.DirectFilled.selector), 1);
        assertEq(eve.balanceOf(address(POOL_MANAGER)), _managerEve, "no EVE left behind in the PoolManager");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_UniversalRouter_SellSettleAfter_FindsNoMarket() public onlyFork {
        uint256 _amount = _routerBuy(BUY_ETH, 0) / SELL_DIVISOR;
        uint256 _eveBefore = eve.balanceOf(address(this));

        // The usual order (swap, then SETTLE_ALL): when the hook runs the PoolManager holds no EVE,
        // so there is nothing to redeem and an empty curve to fall back on.
        uint256 _proceeds = _routerSell(_amount, 0, false);

        assertEq(_proceeds, 0, "no market");
        assertEq(eve.balanceOf(address(this)), _eveBefore, "the seller keeps their EVE");
        _assertHookAndAdapterHoldNothing();
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev SWAP_EXACT_IN_SINGLE (ETH -> EVE), SETTLE_ALL ETH, TAKE_ALL EVE.
    function _routerBuy(uint256 _ethIn, uint256 _minEveOut) internal returns (uint256 _eveOut) {
        bytes memory _actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
        bytes[] memory _params = new bytes[](3);
        _params[0] = abi.encode(_swapParams(true, _ethIn, _minEveOut));
        _params[1] = abi.encode(poolKey.currency0, _ethIn);
        _params[2] = abi.encode(poolKey.currency1, _minEveOut);

        uint256 _before = eve.balanceOf(address(this));
        _execute(_actions, _params, _ethIn);
        _eveOut = eve.balanceOf(address(this)) - _before;
    }

    /**
     * @dev Sells EVE for ETH through the router.
     * @param _settleFirst SETTLE EVE, then SWAP_EXACT_IN_SINGLE, then TAKE_ALL ETH. Otherwise the usual
     * SWAP_EXACT_IN_SINGLE, SETTLE_ALL EVE, TAKE_ALL ETH.
     */
    function _routerSell(uint256 _eveIn, uint256 _minEthOut, bool _settleFirst) internal returns (uint256 _ethOut) {
        eve.approve(address(PERMIT2), _eveIn);
        PERMIT2.approve(
            address(eve), address(UNIVERSAL_ROUTER), uint160(_eveIn), uint48(block.timestamp) + PERMIT_EXPIRATION_OFFSET
        );

        Currency _eve = poolKey.currency1;
        Currency _eth = poolKey.currency0;
        bytes memory _swap = abi.encode(_swapParams(false, _eveIn, _minEthOut));
        bytes memory _takeEth = abi.encode(_eth, _minEthOut);

        bytes memory _actions;
        bytes[] memory _params = new bytes[](3);
        if (_settleFirst) {
            _actions = abi.encodePacked(SETTLE, SWAP_EXACT_IN_SINGLE, TAKE_ALL);
            _params[0] = abi.encode(_eve, _eveIn, true); // payer is the user, through Permit2
            _params[1] = _swap;
        } else {
            _actions = abi.encodePacked(SWAP_EXACT_IN_SINGLE, SETTLE_ALL, TAKE_ALL);
            _params[0] = _swap;
            _params[1] = abi.encode(_eve, _eveIn);
        }
        _params[2] = _takeEth;

        uint256 _before = address(this).balance;
        _execute(_actions, _params, 0);
        _ethOut = address(this).balance - _before;
    }

    function _execute(bytes memory _actions, bytes[] memory _params, uint256 _value) internal {
        bytes[] memory _inputs = new bytes[](1);
        _inputs[0] = abi.encode(_actions, _params);

        UNIVERSAL_ROUTER.execute{value: _value}(abi.encodePacked(V4_SWAP), _inputs, block.timestamp + DEADLINE_OFFSET);
    }

    function _swapParams(bool _zeroForOne, uint256 _amountIn, uint256 _minOut)
        internal
        view
        returns (ExactInputSingleParams memory)
    {
        return ExactInputSingleParams({
            poolKey: poolKey,
            zeroForOne: _zeroForOne,
            amountIn: uint128(_amountIn),
            amountOutMinimum: uint128(_minOut),
            hookData: ""
        });
    }
}
