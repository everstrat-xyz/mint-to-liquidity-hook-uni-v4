// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, Vm} from "forge-std/Test.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {PoolModifyLiquidityTest} from "@uniswap/v4-core/src/test/PoolModifyLiquidityTest.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-core/test/utils/LiquidityAmounts.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";
import {IEverstratAMM} from "interfaces/integrations/IEverstratAMM.sol";
import {IEverstratRegistry} from "interfaces/integrations/IEverstratRegistry.sol";
import {IEverstratWhitelist} from "interfaces/integrations/IEverstratWhitelist.sol";

import {DeployMintToLiquidity} from "../../script/DeployMintToLiquidity.s.sol";
import {EverstratAMMAdapter} from "../../src/adapters/EverstratAMMAdapter.sol";
import {MintToLiquidityHook} from "../../src/MintToLiquidityHook.sol";

/// @notice Everstrat admin calls the fork tests make as the timelock or the security multisig.
interface IEverstratPausable {
    function pause() external;

    function unpause() external;

    function paused() external view returns (bool);
}

/**
 * @notice Forks mainnet and deploys the hook and the Everstrat adapter with `DeployMintToLiquidity`,
 * against the deployed Everstrat protocol and the deployed Uniswap v4 PoolManager.
 *
 * @dev Run with:
 *        MAINNET_RPC_URL=... forge test --match-path 'test/fork/*'
 *      `MAINNET_FORK_BLOCK` pins a block (needs an archive RPC); unset or 0 means the tip.
 *      Without `MAINNET_RPC_URL` every fork test skips.
 *
 *      Everstrat's NAV is small (about 5.6 ETH in November 2026), so every ETH that enters or leaves
 *      the protocol moves the band noticeably. Tests size their trades in fractions of an ETH and read
 *      the band fresh after anything that touches the protocol.
 */
abstract contract ForkFixture is Test {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for PoolKey;

    uint256 internal constant WAD = 1e18;

    IPoolManager internal constant POOL_MANAGER = IPoolManager(0x000000000004444c5dc75cB358380D2e3dE08A90);
    IEverstratRegistry internal constant REGISTRY = IEverstratRegistry(0x46AA1bd55c19be90d8767e0C22732A7DD31D993D);
    bytes32 internal constant AMM_KEY = keccak256("AMM");
    bytes32 internal constant EVE_KEY = keccak256("EVE");
    bytes32 internal constant WHITELIST_KEY = keccak256("WHITELIST");
    bytes32 internal constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 internal constant SECURITY_ROLE = keccak256("SECURITY_ROLE");

    uint24 internal constant POOL_FEE = 3000; // 0.3%
    int24 internal constant TICK_SPACING = 60;
    uint256 internal constant HOLDER_ETH = 100 ether;
    uint160 internal constant MIN_PRICE_LIMIT = TickMath.MIN_SQRT_PRICE + 1;
    uint160 internal constant MAX_PRICE_LIMIT = TickMath.MAX_SQRT_PRICE - 1;

    DeployMintToLiquidity internal deployScript;
    MintToLiquidityHook internal hook;
    EverstratAMMAdapter internal adapter;
    PoolSwapTest internal swapRouter;
    PoolModifyLiquidityTest internal liquidityRouter;
    IEverstratAMM internal amm;
    IERC20 internal eve;
    IEverstratWhitelist internal whitelist;
    PoolKey internal poolKey;
    PoolId internal poolId;
    address internal everstratAdmin;
    address internal everstratSecurity;
    bool internal forkAvailable;

    address internal beneficiary = makeAddr("beneficiary");
    address internal stranger = makeAddr("stranger");

    modifier onlyFork() {
        if (!forkAvailable) {
            vm.skip(true);
            return;
        }
        _;
    }

    receive() external payable {}

    /*//////////////////////////////////////////////////////////////
                                 SETUP
    //////////////////////////////////////////////////////////////*/

    function setUp() public virtual {
        if (!vm.envExists("MAINNET_RPC_URL")) return;

        uint256 _forkBlock = vm.envOr("MAINNET_FORK_BLOCK", uint256(0));
        if (_forkBlock == 0) vm.createSelectFork(vm.envString("MAINNET_RPC_URL"));
        else vm.createSelectFork(vm.envString("MAINNET_RPC_URL"), _forkBlock);
        forkAvailable = true;

        amm = IEverstratAMM(REGISTRY.getContractByKey(AMM_KEY));
        eve = IERC20(REGISTRY.getContractByKey(EVE_KEY));
        whitelist = IEverstratWhitelist(REGISTRY.getContractByKey(WHITELIST_KEY));
        everstratAdmin = REGISTRY.getRoleMember(ADMIN_ROLE, 0);
        everstratSecurity = REGISTRY.getRoleMember(SECURITY_ROLE, 0);

        deployScript = new DeployMintToLiquidity();
        swapRouter = new PoolSwapTest(POOL_MANAGER);
        liquidityRouter = new PoolModifyLiquidityTest(POOL_MANAGER);

        vm.deal(address(this), HOLDER_ETH);
        eve.approve(address(swapRouter), type(uint256).max);
        eve.approve(address(liquidityRouter), type(uint256).max);
    }

    /**
     * @dev Deploys with the script. The script contract owns the adapter, so the script also
     * registers the pool, as a deployer that owns its adapter would.
     */
    function _deployWithScript() internal returns (DeployMintToLiquidity.Deployment memory _deployment) {
        _deployment = deployScript.deploy(_config(address(deployScript)), address(deployScript));

        hook = _deployment.hook;
        adapter = _deployment.adapter;
        poolKey = _deployment.poolKey;
        poolId = poolKey.toId();
    }

    function _config(address _adapterOwner) internal view returns (DeployMintToLiquidity.Config memory) {
        return DeployMintToLiquidity.Config({
            poolManager: POOL_MANAGER,
            registry: REGISTRY,
            adapterOwner: _adapterOwner,
            beneficiary: beneficiary,
            fee: POOL_FEE,
            tickSpacing: TICK_SPACING
        });
    }

    /*//////////////////////////////////////////////////////////////
                         EVERSTRAT GOVERNANCE
    //////////////////////////////////////////////////////////////*/

    /// @dev What the 48h timelock would execute: put the adapter on the Everstrat whitelist.
    function _whitelistAdapter() internal {
        if (whitelist.isWhitelisted(address(adapter))) return;

        vm.prank(everstratAdmin);
        whitelist.addToWhitelist(_single(address(adapter)));
    }

    function _removeAdapterFromWhitelist() internal {
        vm.prank(everstratAdmin);
        whitelist.removeFromWhitelist(address(adapter));
    }

    /// @dev The security multisig's circuit breaker.
    function _pauseAMM() internal {
        vm.prank(everstratSecurity);
        IEverstratPausable(address(amm)).pause();
    }

    /// @dev Unpausing goes through the timelock.
    function _unpauseAMM() internal {
        vm.prank(everstratAdmin);
        IEverstratPausable(address(amm)).unpause();
    }

    /// @dev Adds ETH the AMM can pay redemptions from. It also raises NAV, so the band moves up.
    function _fundAMMExits(uint256 _amount) internal {
        vm.deal(address(amm), address(amm).balance + _amount);
    }

    /*//////////////////////////////////////////////////////////////
                                ACTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Exact-input buy of EVE with ETH and no price limit.
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

    /// @dev Exact-input sell of EVE for ETH and no price limit.
    function _sell(uint256 _eveIn) internal returns (uint256 _ethOut) {
        uint256 _before = address(this).balance;
        swapRouter.swap(
            poolKey,
            SwapParams({zeroForOne: false, amountSpecified: -int256(_eveIn), sqrtPriceLimitX96: MAX_PRICE_LIMIT}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        _ethOut = address(this).balance - _before;
    }

    /// @dev Adds full-range liquidity worth `_ethAmount` of ETH, plus the EVE that pairs with it.
    function _addFullRangeLiquidity(uint256 _ethAmount, uint256 _eveAmount) internal {
        int24 _tickLower = TickMath.minUsableTick(TICK_SPACING);
        int24 _tickUpper = TickMath.maxUsableTick(TICK_SPACING);
        uint128 _liquidity = LiquidityAmounts.getLiquidityForAmounts(
            _sqrtPrice(),
            TickMath.getSqrtPriceAtTick(_tickLower),
            TickMath.getSqrtPriceAtTick(_tickUpper),
            _ethAmount,
            _eveAmount
        );

        liquidityRouter.modifyLiquidity{value: _ethAmount}(
            poolKey,
            ModifyLiquidityParams({
                tickLower: _tickLower,
                tickUpper: _tickUpper,
                liquidityDelta: int256(uint256(_liquidity)),
                salt: bytes32(0)
            }),
            ""
        );
    }

    /*//////////////////////////////////////////////////////////////
                                 VIEWS
    //////////////////////////////////////////////////////////////*/

    function _sqrtPrice() internal view returns (uint160 _sqrtPriceX96) {
        (_sqrtPriceX96,,,) = POOL_MANAGER.getSlot0(poolId);
    }

    function _band() internal view returns (IMintToLiquidityHook.Band memory _currentBand) {
        bool _valid;
        (_valid, _currentBand) = hook.getBand(poolId);
        assertTrue(_valid, "band is invalid");
    }

    /// @dev EVE is currency1, so a higher EVE price is a lower sqrtPrice.
    function _isAboveCeiling() internal view returns (bool) {
        return BandMath.isAboveCeiling(_sqrtPrice(), _band(), false);
    }

    function _isBelowFloor() internal view returns (bool) {
        return BandMath.isBelowFloor(_sqrtPrice(), _band(), false);
    }

    function _assertHookAndAdapterHoldNothing() internal view {
        assertEq(eve.balanceOf(address(hook)), 0, "hook holds EVE");
        assertEq(address(hook).balance, 0, "hook holds ETH");
        assertEq(eve.balanceOf(address(adapter)), 0, "adapter holds EVE");
        assertEq(address(adapter).balance, 0, "adapter holds ETH");
        assertEq(eve.allowance(address(hook), address(adapter)), 0, "hook left an approval");
    }

    /// @dev Decodes every hook event of one type recorded since `vm.recordLogs()`.
    function _countHookEvents(Vm.Log[] memory _logs, bytes32 _selector) internal view returns (uint256 _count) {
        for (uint256 _i; _i < _logs.length; ++_i) {
            if (_logs[_i].emitter == address(hook) && _logs[_i].topics[0] == _selector) _count++;
        }
    }

    function _single(address _account) internal pure returns (address[] memory _accounts) {
        _accounts = new address[](1);
        _accounts[0] = _account;
    }
}
