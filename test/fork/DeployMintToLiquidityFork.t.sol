// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";

import {BandMath} from "libraries/BandMath.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";
import {IEverstratRegistry} from "interfaces/integrations/IEverstratRegistry.sol";

import {DeployMintToLiquidity} from "../../script/DeployMintToLiquidity.s.sol";
import {MintToLiquidityHook} from "../../src/MintToLiquidityHook.sol";
import {ForkFixture} from "./ForkFixture.sol";

/**
 * @notice `DeployMintToLiquidity` against mainnet: what it deploys, how it wires it, and what it refuses.
 */
contract DeployMintToLiquidityForkTest is ForkFixture {
    using StateLibrary for IPoolManager;
    using PoolIdLibrary for *;

    uint256 internal constant DEPLOYER_ETH = 1 ether;

    address internal multisig = makeAddr("multisig");

    /*//////////////////////////////////////////////////////////////
                           DEPLOYER OWNS ADAPTER
    //////////////////////////////////////////////////////////////*/

    function test_Fork_Deploy_HookAddressCarriesItsPermissions() public onlyFork {
        DeployMintToLiquidity.Deployment memory _deployment = _deployWithScript();

        // v4 reads permissions from the address: exactly these four bits, nothing else.
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, deployScript.HOOK_FLAGS());
        Hooks.Permissions memory _permissions = hook.getHookPermissions();
        assertTrue(_permissions.beforeInitialize && _permissions.beforeSwap && _permissions.afterSwap);
        assertTrue(_permissions.beforeSwapReturnDelta);

        // Deployed through the CREATE2 proxy at the mined salt.
        bytes32 _initCodeHash =
            keccak256(abi.encodePacked(type(MintToLiquidityHook).creationCode, abi.encode(POOL_MANAGER)));
        assertEq(address(hook), vm.computeCreate2Address(_deployment.hookSalt, _initCodeHash, CREATE2_FACTORY));
        assertEq(address(hook.poolManager()), address(POOL_MANAGER));
    }

    function test_Fork_Deploy_WiresTheAdapter() public onlyFork {
        _deployWithScript();

        assertEq(address(adapter.AMM()), address(amm));
        assertEq(address(adapter.EVE()), address(eve));
        assertEq(adapter.HOOK(), address(hook));
        assertEq(adapter.owner(), address(deployScript));
        assertEq(adapter.beneficiary(), beneficiary);
    }

    function test_Fork_Deploy_RegistersPoolAtBandMidpoint() public onlyFork {
        DeployMintToLiquidity.Deployment memory _deployment = _deployWithScript();

        assertTrue(_deployment.poolRegistered);
        IMintToLiquidityHook.PoolConfig memory _poolConfig = hook.poolConfig(poolId);
        assertEq(address(_poolConfig.adapter), address(adapter));
        assertFalse(_poolConfig.tokenIsCurrency0, "EVE is currency1 against native ETH");
        assertTrue(poolKey.currency0.isAddressZero());
        assertEq(poolKey.fee, POOL_FEE);
        assertEq(poolKey.tickSpacing, TICK_SPACING);

        // The pool opens inside the live Everstrat band, at its midpoint, with no liquidity.
        assertEq(_sqrtPrice(), BandMath.midSqrtPriceX96(_band(), false));
        assertFalse(_isAboveCeiling());
        assertFalse(_isBelowFloor());
        assertEq(POOL_MANAGER.getLiquidity(poolId), 0);
    }

    function test_Fork_Deploy_SecondDeploymentGetsANewHookAddress() public onlyFork {
        DeployMintToLiquidity.Deployment memory _first = _deployWithScript();
        DeployMintToLiquidity.Deployment memory _second =
            deployScript.deploy(_config(address(deployScript)), address(deployScript));

        // The miner skips addresses that already have code, so a redeploy cannot collide.
        assertTrue(address(_second.hook) != address(_first.hook));
        assertEq(uint160(address(_second.hook)) & Hooks.ALL_HOOK_MASK, deployScript.HOOK_FLAGS());
    }

    /*//////////////////////////////////////////////////////////////
                          MULTISIG OWNS ADAPTER
    //////////////////////////////////////////////////////////////*/

    function test_Fork_Deploy_LeavesRegistrationToTheOwner() public onlyFork {
        DeployMintToLiquidity.Deployment memory _deployment =
            deployScript.deploy(_config(multisig), address(deployScript));
        hook = _deployment.hook;
        adapter = _deployment.adapter;

        assertFalse(_deployment.poolRegistered);
        assertEq(address(hook.poolConfig(_deployment.poolKey.toId()).adapter), address(0));
        assertEq(adapter.owner(), multisig);

        // The deployer cannot register it...
        vm.expectRevert(IMintToLiquidityHook.MintToLiquidityHookNotAdapterOwner.selector);
        hook.registerPool(adapter, POOL_FEE, TICK_SPACING);

        // ...and the owner's call, the one the script prints, registers the key the script predicted.
        vm.prank(multisig);
        (bool _ok,) =
            address(hook).call(abi.encodeCall(IMintToLiquidityHook.registerPool, (adapter, POOL_FEE, TICK_SPACING)));
        assertTrue(_ok);
        assertEq(address(hook.poolConfig(_deployment.poolKey.toId()).adapter), address(adapter));
    }

    /*//////////////////////////////////////////////////////////////
                              run() FROM ENV
    //////////////////////////////////////////////////////////////*/

    function test_Fork_Run_BroadcastsFromTheEnvironment() public onlyFork {
        (address _deployer, uint256 _deployerKey) = makeAddrAndKey("deployer");
        vm.deal(_deployer, DEPLOYER_ETH);
        _setEnv(_deployerKey, _deployer, POOL_FEE, TICK_SPACING);

        DeployMintToLiquidity.Deployment memory _deployment = deployScript.run();

        // The broadcaster owns the adapter, so the script registered the pool from the broadcaster.
        assertTrue(_deployment.poolRegistered);
        assertEq(_deployment.adapter.owner(), _deployer);
        assertEq(address(_deployment.hook.poolConfig(_deployment.poolKey.toId()).adapter), address(_deployment.adapter));
    }

    function test_Fork_Run_InvalidEnvironment() public onlyFork {
        (, uint256 _deployerKey) = makeAddrAndKey("deployer");

        _setEnv(_deployerKey, stranger, LPFeeLibrary.MAX_LP_FEE + 1, TICK_SPACING);
        vm.expectRevert("POOL_FEE above 100%");
        deployScript.run();

        _setEnv(_deployerKey, stranger, POOL_FEE, 0);
        vm.expectRevert("TICK_SPACING out of range");
        deployScript.run();
    }

    /*//////////////////////////////////////////////////////////////
                              INVALID CONFIG
    //////////////////////////////////////////////////////////////*/

    function test_Fork_Deploy_InvalidConfig() public onlyFork {
        DeployMintToLiquidity.Config memory _bad = _config(multisig);
        _bad.beneficiary = address(0);
        vm.expectRevert("BENEFICIARY_ADDRESS is zero");
        deployScript.deploy(_bad, address(deployScript));

        _bad = _config(address(0));
        vm.expectRevert("ADAPTER_OWNER_ADDRESS is zero");
        deployScript.deploy(_bad, address(deployScript));

        _bad = _config(multisig);
        _bad.poolManager = IPoolManager(stranger);
        vm.expectRevert("POOL_MANAGER_ADDRESS has no code");
        deployScript.deploy(_bad, address(deployScript));

        _bad = _config(multisig);
        _bad.registry = IEverstratRegistry(address(eve));
        vm.expectRevert();
        deployScript.deploy(_bad, address(deployScript));

        _bad = _config(multisig);
        _bad.fee = LPFeeLibrary.DYNAMIC_FEE_FLAG;
        vm.expectRevert("dynamic fees are not supported");
        deployScript.deploy(_bad, address(deployScript));
    }

    function test_Fork_Deploy_WhenAMMPaused_StillDeploys() public onlyFork {
        // The band is a view, so a paused AMM does not stop the deployment; the hook stands aside
        // until the AMM is unpaused.
        _pauseAMM();

        DeployMintToLiquidity.Deployment memory _deployment = _deployWithScript();

        assertTrue(_deployment.poolRegistered);
    }

    /*//////////////////////////////////////////////////////////////
                                HELPERS
    //////////////////////////////////////////////////////////////*/

    function _setEnv(uint256 _deployerKey, address _adapterOwner, uint256 _fee, int256 _tickSpacing) internal {
        vm.setEnv("PRIVATE_KEY", vm.toString(bytes32(_deployerKey)));
        vm.setEnv("POOL_MANAGER_ADDRESS", vm.toString(address(POOL_MANAGER)));
        vm.setEnv("EVERSTRAT_REGISTRY_ADDRESS", vm.toString(address(REGISTRY)));
        vm.setEnv("ADAPTER_OWNER_ADDRESS", vm.toString(_adapterOwner));
        vm.setEnv("BENEFICIARY_ADDRESS", vm.toString(beneficiary));
        vm.setEnv("POOL_FEE", vm.toString(_fee));
        vm.setEnv("TICK_SPACING", vm.toString(_tickSpacing));
    }
}
