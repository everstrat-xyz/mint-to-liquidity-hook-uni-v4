// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IEverstratAMMAdapter} from "interfaces/adapters/IEverstratAMMAdapter.sol";
import {IEverstratAMM} from "interfaces/integrations/IEverstratAMM.sol";

import {EverstratAMMAdapter} from "../../src/adapters/EverstratAMMAdapter.sol";
import {MockEverstratAMM} from "../mocks/MockEverstratAMM.sol";
import {MockToken} from "../mocks/MockToken.sol";

contract EverstratAMMAdapterTest is Test {
    uint256 internal constant WAD = 1e18;
    uint8 internal constant EVE_DECIMALS = 18;
    /// @dev Live mainnet values on 2026-11-12, so the rounding is the one the real AMM produces.
    uint256 internal constant BASE_PRICE = 564277173113183;
    uint256 internal constant CONNECTOR_WEIGHT = 0.9e18;
    uint256 internal constant AMM_FREE_ETH = 10 ether;
    uint256 internal constant MINT_ETH = 1 ether;
    uint256 internal constant REDEEM_TOKENS = 1_000e18;
    /// @dev The AMM can pay one wei less than `tokens * basePrice`.
    uint256 internal constant EXIT_ROUNDING = 1;
    uint256 internal constant MIN_FUZZ_BASE_PRICE = 1e12;
    uint256 internal constant MIN_FUZZ_TOKENS = 1e12;
    uint256 internal constant MAX_FUZZ_TOKENS = 1_000_000e18;

    EverstratAMMAdapter internal adapter;
    MockEverstratAMM internal amm;
    MockToken internal eve;

    address internal hook = makeAddr("hook");
    address internal owner = makeAddr("owner");
    address internal beneficiary = makeAddr("beneficiary");
    address internal stranger = makeAddr("stranger");

    function setUp() public {
        eve = new MockToken("Everstrat", "EVE", EVE_DECIMALS);
        amm = new MockEverstratAMM(eve, BASE_PRICE, CONNECTOR_WEIGHT);
        adapter = new EverstratAMMAdapter(IEverstratAMM(address(amm)), eve, hook, owner, beneficiary);

        vm.deal(address(amm), AMM_FREE_ETH);
        vm.deal(hook, MINT_ETH);
        eve.mint(hook, REDEEM_TOKENS);
        vm.prank(hook);
        eve.approve(address(adapter), type(uint256).max);
    }

    function test_Constructor_InvalidInputs() public {
        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterZeroAddress.selector);
        new EverstratAMMAdapter(IEverstratAMM(address(0)), eve, hook, owner, beneficiary);

        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterZeroAddress.selector);
        new EverstratAMMAdapter(IEverstratAMM(address(amm)), IERC20(address(0)), hook, owner, beneficiary);

        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterZeroAddress.selector);
        new EverstratAMMAdapter(IEverstratAMM(address(amm)), eve, address(0), owner, beneficiary);

        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterZeroAddress.selector);
        new EverstratAMMAdapter(IEverstratAMM(address(amm)), eve, hook, owner, address(0));
    }

    function test_Views() public view {
        assertEq(address(adapter.token()), address(eve));
        assertTrue(adapter.quoteCurrency().isAddressZero());
        assertEq(adapter.mintPrice(), amm.evePremiumPriceInETH());
        assertEq(adapter.redeemPrice(), BASE_PRICE);
        assertEq(adapter.maxRedeemNow(), AMM_FREE_ETH);
        assertEq(adapter.owner(), owner);
        assertEq(adapter.beneficiary(), beneficiary);
    }

    function test_Mint() public {
        uint256 _expected = (MINT_ETH * WAD) / adapter.mintPrice();
        uint256 _before = eve.balanceOf(hook);

        vm.prank(hook);
        uint256 _tokensOut = adapter.mint{value: MINT_ETH}(MINT_ETH, _expected);

        assertEq(_tokensOut, _expected);
        assertEq(eve.balanceOf(hook), _before + _expected);
        assertEq(eve.balanceOf(address(adapter)), 0);
    }

    function test_Mint_InvalidInputs() public {
        vm.startPrank(hook);

        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterValueMismatch.selector);
        adapter.mint{value: MINT_ETH - 1}(MINT_ETH, 1);

        // The AMM's own slippage check carries the hook's minimum.
        uint256 _tooMany = (MINT_ETH * WAD) / adapter.mintPrice() + 1;
        vm.expectRevert(MockEverstratAMM.MockEverstratAMMInsufficientDeposit.selector);
        adapter.mint{value: MINT_ETH}(MINT_ETH, _tooMany);

        vm.stopPrank();
    }

    function test_Mint_AccessControl() public {
        vm.deal(stranger, MINT_ETH);
        vm.prank(stranger);
        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterCallerNotHook.selector);
        adapter.mint{value: MINT_ETH}(MINT_ETH, 1);
    }

    function test_Redeem() public {
        uint256 _owed = (REDEEM_TOKENS * BASE_PRICE) / WAD;
        uint256 _ethBefore = hook.balance;

        vm.prank(hook);
        uint256 _quoteOut = adapter.redeem(REDEEM_TOKENS, _owed - EXIT_ROUNDING);

        // The AMM's two roundings cost at most one wei, and the EVE they leave unburned comes back.
        assertGe(_quoteOut, _owed - EXIT_ROUNDING);
        assertLe(_quoteOut, _owed);
        assertEq(hook.balance, _ethBefore + _quoteOut);
        assertLt(eve.balanceOf(hook), WAD, "only dust comes back");
        assertEq(eve.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
        assertEq(eve.allowance(address(adapter), address(amm)), 0);
    }

    function testFuzz_Redeem_PaysWithinOneWei(uint256 _tokens, uint256 _basePrice) public {
        // The one-wei bound holds while one EVE is worth at most one ETH (it is worth ~0.0006 ETH).
        _basePrice = bound(_basePrice, MIN_FUZZ_BASE_PRICE, WAD);
        _tokens = bound(_tokens, MIN_FUZZ_TOKENS, MAX_FUZZ_TOKENS);
        amm = new MockEverstratAMM(eve, _basePrice, CONNECTOR_WEIGHT);
        adapter = new EverstratAMMAdapter(IEverstratAMM(address(amm)), eve, hook, owner, beneficiary);
        uint256 _owed = (_tokens * _basePrice) / WAD;
        vm.assume(_owed > EXIT_ROUNDING);
        vm.deal(address(amm), _owed);
        eve.mint(hook, _tokens);

        vm.startPrank(hook);
        eve.approve(address(adapter), _tokens);
        uint256 _quoteOut = adapter.redeem(_tokens, _owed - EXIT_ROUNDING);
        vm.stopPrank();

        assertGe(_quoteOut, _owed - EXIT_ROUNDING);
    }

    function test_Redeem_QueuedExit() public {
        // The AMM cannot pay now, so it would queue. The adapter reverts and nothing is escrowed.
        vm.deal(address(amm), 0);

        vm.prank(hook);
        vm.expectRevert(abi.encodeWithSelector(IEverstratAMMAdapter.EverstratAMMAdapterQueuedExit.selector, 1));
        adapter.redeem(REDEEM_TOKENS, 1);

        assertEq(amm.queuedTokens(), 0);
        assertEq(eve.balanceOf(hook), REDEEM_TOKENS);
    }

    function test_Redeem_InvalidInputs() public {
        uint256 _owed = (REDEEM_TOKENS * BASE_PRICE) / WAD;

        vm.prank(hook);
        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterInsufficientOutput.selector);
        adapter.redeem(REDEEM_TOKENS, _owed + 1);
    }

    function test_Redeem_AccessControl() public {
        vm.prank(stranger);
        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterCallerNotHook.selector);
        adapter.redeem(REDEEM_TOKENS, 1);
    }

    function test_Receive_AccessControl() public {
        vm.deal(stranger, MINT_ETH);
        vm.prank(stranger);
        (bool _sent,) = address(adapter).call{value: MINT_ETH}("");

        assertFalse(_sent);
    }

    function test_SetBeneficiary() public {
        vm.expectEmit(true, true, false, false, address(adapter));
        emit IEverstratAMMAdapter.BeneficiaryChanged(beneficiary, stranger);
        vm.prank(owner);
        adapter.setBeneficiary(stranger);

        assertEq(adapter.beneficiary(), stranger);
    }

    function test_SetBeneficiary_InvalidInputs() public {
        vm.prank(owner);
        vm.expectRevert(IEverstratAMMAdapter.EverstratAMMAdapterZeroAddress.selector);
        adapter.setBeneficiary(address(0));
    }

    function test_SetBeneficiary_AccessControl() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(Ownable.OwnableUnauthorizedAccount.selector, stranger));
        adapter.setBeneficiary(stranger);
    }
}
