// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";
import {IEverstratAMM} from "interfaces/integrations/IEverstratAMM.sol";

import {EverstratAMMAdapter} from "../../src/adapters/EverstratAMMAdapter.sol";
import {MintToLiquidityHook} from "../../src/MintToLiquidityHook.sol";

interface IEverstratRegistry {
    function getContractByKey(bytes32 _key) external view returns (address);

    function getRoleMember(bytes32 _role, uint256 _index) external view returns (address);
}

interface IEverstratWhitelist {
    function addToWhitelist(address[] calldata _users) external;

    function isWhitelisted(address _user) external view returns (bool);
}

/**
 * @notice The hook and the Everstrat adapter against the deployed Everstrat AMM and the deployed
 * Uniswap v4 PoolManager, on a mainnet fork.
 *
 * @dev Run with:
 *        MAINNET_RPC_URL=... forge test --match-path 'test/fork/*'
 *      `MAINNET_FORK_BLOCK` pins a block (needs an archive RPC); unset or 0 means the tip.
 *      Without `MAINNET_RPC_URL` every test here skips.
 */
contract EverstratAMMAdapterForkTest is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = 1e18;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IEverstratRegistry internal constant REGISTRY = IEverstratRegistry(0x46AA1bd55c19be90d8767e0C22732A7DD31D993D);
    bytes32 internal constant AMM_KEY = keccak256("AMM");
    bytes32 internal constant EVE_KEY = keccak256("EVE");
    bytes32 internal constant WHITELIST_KEY = keccak256("WHITELIST");
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");

    bytes32 internal constant ADAPTER_SALT = keccak256("EverstratAMMAdapterForkTest");
    uint24 internal constant POOL_FEE = 3000;
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant BUY_ETH = 1 ether;
    uint256 internal constant HOLDER_ETH = 100 ether;
    /// @dev ETH given to the AMM so redemptions can be paid at once; live, its free balance is often zero.
    uint256 internal constant AMM_EXIT_LIQUIDITY = 5 ether;
    uint256 internal constant SELL_DIVISOR = 2; // sell half of what was bought
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    MintToLiquidityHook internal hook;
    EverstratAMMAdapter internal adapter;
    PoolSwapTest internal swapRouter;
    IEverstratAMM internal amm;
    IERC20 internal eve;
    PoolKey internal poolKey;
    PoolId internal poolId;
    bool internal forkAvailable;

    address internal adapterOwner = makeAddr("adapterOwner");
    address internal beneficiary = makeAddr("beneficiary");

    receive() external payable {}

    function setUp() public {
        if (!vm.envExists("MAINNET_RPC_URL")) return;

        uint256 _forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (_forkBlock == 0) vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        else vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), _forkBlock);
        forkAvailable = true;

        amm = IEverstratAMM(REGISTRY.getContractByKey(AMM_KEY));
        eve = IERC20(REGISTRY.getContractByKey(EVE_KEY));

        address _hookAddress = address(
            uint160(
                Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
                    | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
            ) ^ (0x4444 << 144)
        );
        deployCodeTo("MintToLiquidityHook.sol:MintToLiquidityHook", abi.encode(POOL_MANAGER), _hookAddress);
        hook = MintToLiquidityHook(payable(_hookAddress));
        // A fixed salt keeps the adapter off the default test-deployment addresses, which hold dust on mainnet.
        adapter = new EverstratAMMAdapter{salt: ADAPTER_SALT}(amm, eve, address(hook), adapterOwner, beneficiary);
        swapRouter = new PoolSwapTest(POOL_MANAGER);

        vm.prank(adapterOwner);
        poolKey = hook.registerPool(adapter, POOL_FEE, TICK_SPACING);
        poolId = poolKey.toId();

        vm.deal(address(this), HOLDER_ETH);
        eve.approve(address(swapRouter), type(uint256).max);
    }

    modifier onlyFork() {
        if (!forkAvailable) {
            vm.skip(true);
            return;
        }
        _;
    }

    function test_Fork_AdapterQuotesTheAMM() public onlyFork {
        assertEq(adapter.mintPrice(), amm.evePremiumPriceInETH());
        assertEq(adapter.redeemPrice(), amm.eveBasePriceInETH());
        assertEq(adapter.maxRedeemNow(), amm.freeBalance());
        assertGt(adapter.mintPrice(), adapter.redeemPrice(), "EVE mints at a premium over NAV");

        (bool _valid, IMintToLiquidityHook.Band memory _band) = hook.getBand(poolId);
        (uint160 _sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
        assertTrue(_valid);
        // Native ETH is currency0, so EVE is currency1.
        assertTrue(poolKey.currency0.isAddressZero());
        assertEq(_sqrtPriceX96, BandMath.midSqrtPriceX96(_band, false));
    }

    function test_Fork_Buy_MintsThroughTheAMM() public onlyFork {
        _whitelistAdapter();
        uint256 _ceiling = amm.evePremiumPriceInETH();
        uint256 _floorBefore = amm.eveBasePriceInETH();
        uint256 _supplyBefore = eve.totalSupply();

        // No liquidity was ever added: the pool's market is the issuer.
        uint256 _bought = _buy(BUY_ETH);

        assertEq(_bought, BandMath.tokensForQuoteDown(BUY_ETH, _ceiling), "minted at the premium price");
        assertEq(eve.totalSupply(), _supplyBefore + _bought);
        assertGe(amm.eveBasePriceInETH(), _floorBefore, "minting at a premium does not lower NAV per EVE");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_Buy_AdapterNotWhitelisted() public onlyFork {
        if (IEverstratWhitelist(REGISTRY.getContractByKey(WHITELIST_KEY)).isWhitelisted(address(adapter))) {
            vm.skip(true); // the invite period is over
            return;
        }
        uint256 _supplyBefore = eve.totalSupply();

        // The AMM turns the adapter away; the swap finds an empty curve instead of reverting.
        uint256 _bought = _buy(BUY_ETH);

        assertEq(_bought, 0);
        assertEq(eve.totalSupply(), _supplyBefore);
    }

    function test_Fork_Sell_RedeemsThroughTheAMM() public onlyFork {
        _whitelistAdapter();
        uint256 _bought = _buy(BUY_ETH);
        vm.deal(address(amm), address(amm).balance + AMM_EXIT_LIQUIDITY);
        // The hook can only take EVE the PoolManager already holds; this stands in for other pools.
        uint256 _amount = _bought / SELL_DIVISOR;
        eve.transfer(address(POOL_MANAGER), _amount);

        uint256 _floor = amm.eveBasePriceInETH();
        uint256 _supplyBefore = eve.totalSupply();
        uint256 _ethBefore = address(this).balance;

        _sell(_amount);

        uint256 _proceeds = address(this).balance - _ethBefore;
        assertEq(_proceeds, BandMath.quoteForTokensDown(_amount, _floor) - hook.ROUNDING_SLACK(), "paid at NAV");
        // The AMM burns `floor(eth / price)`, which leaves less than one wei's worth of EVE unburned.
        assertApproxEqAbs(eve.totalSupply(), _supplyBefore - _amount, WAD * WAD / _floor, "redeemed");
        _assertHookAndAdapterHoldNothing();
    }

    function test_Fork_Sell_NoFreeETH_NeverQueues() public onlyFork {
        _whitelistAdapter();
        uint256 _bought = _buy(BUY_ETH);
        uint256 _amount = _bought / SELL_DIVISOR;
        eve.transfer(address(POOL_MANAGER), _amount);
        // The mint above sent its ETH on to the Controller; drain whatever free ETH the AMM has left.
        vm.deal(address(amm), address(amm).balance - amm.freeBalance());

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

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    /// @dev What the 48h timelock would do: put the adapter on the Everstrat whitelist.
    function _whitelistAdapter() internal {
        IEverstratWhitelist _whitelist = IEverstratWhitelist(REGISTRY.getContractByKey(WHITELIST_KEY));
        if (_whitelist.isWhitelisted(address(adapter))) return;

        address[] memory _users = new address[](1);
        _users[0] = address(adapter);
        vm.prank(REGISTRY.getRoleMember(ADMIN_ROLE, 0));
        _whitelist.addToWhitelist(_users);
    }

    function _buy(uint256 _ethIn) internal returns (uint256 _eveOut) {
        uint256 _before = eve.balanceOf(address(this));
        swapRouter.swap{value: _ethIn}(
            poolKey,
            SwapParams({zeroForOne: true, amountSpecified: -int256(_ethIn), sqrtPriceLimitX96: MIN_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _eveOut = eve.balanceOf(address(this)) - _before;
    }

    function _sell(uint256 _eveIn) internal {
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(_eveIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
    }

    function _assertHookAndAdapterHoldNothing() internal view {
        assertEq(eve.balanceOf(address(hook)), 0);
        assertEq(address(hook).balance, 0);
        assertEq(eve.balanceOf(address(adapter)), 0);
        assertEq(address(adapter).balance, 0);
    }
}
