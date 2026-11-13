// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script, console} from "forge-std/Script.sol";

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";

import {IMintToLiquidityHook} from "interfaces/IMintToLiquidityHook.sol";
import {IEverstratAMM} from "interfaces/integrations/IEverstratAMM.sol";
import {IEverstratRegistry} from "interfaces/integrations/IEverstratRegistry.sol";
import {IEverstratWhitelist} from "interfaces/integrations/IEverstratWhitelist.sol";

import {EverstratAMMAdapter} from "../src/adapters/EverstratAMMAdapter.sol";
import {MintToLiquidityHook} from "../src/MintToLiquidityHook.sol";

/**
 * @title DeployMintToLiquidity
 * @notice Deploys the Mint-to-Liquidity hook and the Everstrat adapter, and registers the EVE/ETH pool
 * when the deployer owns the adapter.
 *
 * @dev Env (all required, none defaulted):
 *      - `PRIVATE_KEY`: the deployer.
 *      - `POOL_MANAGER_ADDRESS`: the Uniswap v4 PoolManager (mainnet `0x000000000004444c5dc75cB358380D2e3dE08A90`).
 *      - `EVERSTRAT_REGISTRY_ADDRESS`: the Everstrat Registry; the AMM and EVE are read from it.
 *      - `ADAPTER_OWNER_ADDRESS`: who may register pools for the adapter and set its beneficiary.
 *      - `BENEFICIARY_ADDRESS`: who receives the hook's profit (the Controller or the AMM, README §11).
 *      - `POOL_FEE`: the pool's static LP fee in pips (3000 = 0.3%).
 *      - `TICK_SPACING`: the pool's tick spacing.
 *
 *      The hook is deployed through the CREATE2 deployer proxy at a mined salt, because v4 reads a
 *      hook's permissions from the low 14 bits of its address. The proxy makes the address the same
 *      whether this runs as a broadcast or inside a test.
 *
 *      When the deployer is not the adapter owner (a multisig, say), the pool is left unregistered
 *      and the script prints the `registerPool` call for the owner to send. Either way it prints the
 *      Everstrat whitelist call the 48h timelock has to schedule before the adapter can mint.
 *
 *      Usage (README §10):
 *        forge script script/DeployMintToLiquidity.s.sol --rpc-url <rpc>                       # dry run
 *        forge script script/DeployMintToLiquidity.s.sol --rpc-url <rpc> --broadcast --verify
 *      The hook is created by a raw call to the CREATE2 proxy; verify it with `forge verify-contract`
 *      if `--verify` does not pick it up.
 */
contract DeployMintToLiquidity is Script {
    using PoolIdLibrary for PoolKey;
    using StateLibrary for IPoolManager;

    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct Config {
        IPoolManager poolManager;
        IEverstratRegistry registry;
        address adapterOwner;
        address beneficiary;
        uint24 fee;
        int24 tickSpacing;
    }

    struct Deployment {
        MintToLiquidityHook hook;
        EverstratAMMAdapter adapter;
        PoolKey poolKey;
        bool poolRegistered;
        bytes32 hookSalt;
    }

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice The permissions `MintToLiquidityHook.getHookPermissions()` declares, as address bits.
    uint160 public constant HOOK_FLAGS = uint160(
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_SWAP_FLAG | Hooks.AFTER_SWAP_FLAG
            | Hooks.BEFORE_SWAP_RETURNS_DELTA_FLAG
    );

    /// @notice Salts tried before giving up. A match takes 2^14 = 16,384 tries on average.
    uint256 public constant MAX_SALT_ITERATIONS = 1_000_000;

    bytes32 internal constant _AMM_KEY = keccak256("AMM");
    bytes32 internal constant _EVE_KEY = keccak256("EVE");
    bytes32 internal constant _WHITELIST_KEY = keccak256("WHITELIST");

    /*//////////////////////////////////////////////////////////////
                                 ENTRY
    //////////////////////////////////////////////////////////////*/

    function run() external returns (Deployment memory _deployment) {
        uint256 _deployerKey = vm.envUint("PRIVATE_KEY");
        address _deployer = vm.addr(_deployerKey);
        Config memory _config = configFromEnv();

        console.log("Deployer:", _deployer);

        vm.startBroadcast(_deployerKey);
        _deployment = deploy(_config, _deployer);
        vm.stopBroadcast();

        _logNextSteps(_config, _deployment);
    }

    /**
     * @notice Reads and range-checks the configuration from the environment.
     */
    function configFromEnv() public view returns (Config memory) {
        uint256 _fee = vm.envUint("POOL_FEE");
        int256 _tickSpacing = vm.envInt("TICK_SPACING");
        require(_fee <= LPFeeLibrary.MAX_LP_FEE, "POOL_FEE above 100%");
        require(
            _tickSpacing >= TickMath.MIN_TICK_SPACING && _tickSpacing <= TickMath.MAX_TICK_SPACING,
            "TICK_SPACING out of range"
        );

        return Config({
            poolManager: IPoolManager(vm.envAddress("POOL_MANAGER_ADDRESS")),
            registry: IEverstratRegistry(vm.envAddress("EVERSTRAT_REGISTRY_ADDRESS")),
            adapterOwner: vm.envAddress("ADAPTER_OWNER_ADDRESS"),
            beneficiary: vm.envAddress("BENEFICIARY_ADDRESS"),
            // Safe: both were range-checked above.
            fee: uint24(_fee),
            tickSpacing: int24(_tickSpacing)
        });
    }

    /**
     * @notice Deploys and wires everything. Public so the fork tests run the exact deployment path.
     * @param _config What to deploy against.
     * @param _caller The address the hook sees as `msg.sender`: the broadcaster in a script, this
     * contract in a test. The pool is registered only when it owns the adapter.
     */
    function deploy(Config memory _config, address _caller) public returns (Deployment memory _deployment) {
        (IEverstratAMM _amm, IERC20 _eve) = _validate(_config);

        (_deployment.hook, _deployment.hookSalt) = _deployHook(_config.poolManager);
        _deployment.adapter =
            new EverstratAMMAdapter(_amm, _eve, address(_deployment.hook), _config.adapterOwner, _config.beneficiary);

        // Native ETH is address zero, so it is always currency0 and EVE is always currency1.
        _deployment.poolKey = PoolKey({
            currency0: Currency.wrap(address(0)),
            currency1: Currency.wrap(address(_eve)),
            fee: _config.fee,
            tickSpacing: _config.tickSpacing,
            hooks: IHooks(address(_deployment.hook))
        });

        if (_caller == _config.adapterOwner) {
            PoolKey memory _registered =
                _deployment.hook.registerPool(_deployment.adapter, _config.fee, _config.tickSpacing);
            require(
                PoolId.unwrap(_registered.toId()) == PoolId.unwrap(_deployment.poolKey.toId()),
                "CRITICAL: registered an unexpected pool"
            );
            _deployment.poolRegistered = true;
        }

        _verify(_config, _deployment, _amm, _eve);
    }

    /*//////////////////////////////////////////////////////////////
                                INTERNAL
    //////////////////////////////////////////////////////////////*/

    function _validate(Config memory _config) internal view returns (IEverstratAMM _amm, IERC20 _eve) {
        require(address(_config.poolManager).code.length != 0, "POOL_MANAGER_ADDRESS has no code");
        require(address(_config.registry).code.length != 0, "EVERSTRAT_REGISTRY_ADDRESS has no code");
        require(_config.adapterOwner != address(0), "ADAPTER_OWNER_ADDRESS is zero");
        require(_config.beneficiary != address(0), "BENEFICIARY_ADDRESS is zero");
        require(!LPFeeLibrary.isDynamicFee(_config.fee), "dynamic fees are not supported");

        _amm = IEverstratAMM(_config.registry.getContractByKey(_AMM_KEY));
        _eve = IERC20(_config.registry.getContractByKey(_EVE_KEY));
        require(address(_amm).code.length != 0, "registry AMM has no code");
        require(address(_eve).code.length != 0, "registry EVE has no code");

        // The band must be readable and valid, or `registerPool` would revert later.
        uint256 _ceiling = _amm.evePremiumPriceInETH();
        uint256 _floor = _amm.eveBasePriceInETH();
        require(_ceiling != 0 && _floor <= _ceiling, "Everstrat AMM band is invalid");
    }

    /**
     * @dev Mines a salt that gives the hook exactly its permission bits, then deploys through the
     * CREATE2 deployer proxy.
     */
    function _deployHook(IPoolManager _poolManager) internal returns (MintToLiquidityHook _hook, bytes32 _salt) {
        bytes memory _initCode = abi.encodePacked(type(MintToLiquidityHook).creationCode, abi.encode(_poolManager));

        address _expected;
        (_expected, _salt) = mineSalt(keccak256(_initCode));

        (bool _ok, bytes memory _returned) = CREATE2_FACTORY.call(abi.encodePacked(_salt, _initCode));
        require(_ok && address(bytes20(_returned)) == _expected, "CRITICAL: hook deployment failed");

        _hook = MintToLiquidityHook(payable(_expected));
    }

    /**
     * @notice Finds the first salt whose CREATE2 address carries exactly `HOOK_FLAGS` and is free.
     * @param _initCodeHash `keccak256` of the hook's creation code with constructor arguments.
     */
    function mineSalt(bytes32 _initCodeHash) public view returns (address _hook, bytes32 _salt) {
        for (uint256 _i; _i < MAX_SALT_ITERATIONS; ++_i) {
            _salt = bytes32(_i);
            _hook = vm.computeCreate2Address(_salt, _initCodeHash, CREATE2_FACTORY);
            if (uint160(_hook) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS && _hook.code.length == 0) return (_hook, _salt);
        }
        revert("no hook salt found");
    }

    function _verify(Config memory _config, Deployment memory _deployment, IEverstratAMM _amm, IERC20 _eve)
        internal
        view
    {
        MintToLiquidityHook _hook = _deployment.hook;
        EverstratAMMAdapter _adapter = _deployment.adapter;

        require(address(_hook.poolManager()) == address(_config.poolManager), "CRITICAL: hook poolManager mismatch");
        require(uint160(address(_hook)) & Hooks.ALL_HOOK_MASK == HOOK_FLAGS, "CRITICAL: hook address flags");

        require(address(_adapter.AMM()) == address(_amm), "CRITICAL: adapter AMM mismatch");
        require(address(_adapter.EVE()) == address(_eve), "CRITICAL: adapter EVE mismatch");
        require(_adapter.HOOK() == address(_hook), "CRITICAL: adapter HOOK mismatch");
        require(_adapter.owner() == _config.adapterOwner, "CRITICAL: adapter owner mismatch");
        require(_adapter.beneficiary() == _config.beneficiary, "CRITICAL: adapter beneficiary mismatch");

        if (_deployment.poolRegistered) {
            IMintToLiquidityHook.PoolConfig memory _poolConfig = _hook.poolConfig(_deployment.poolKey.toId());
            require(address(_poolConfig.adapter) == address(_adapter), "CRITICAL: pool not bound to adapter");
            require(!_poolConfig.tokenIsCurrency0, "CRITICAL: EVE must be currency1");

            (uint160 _sqrtPriceX96,,,) = _config.poolManager.getSlot0(_deployment.poolKey.toId());
            require(_sqrtPriceX96 != 0, "CRITICAL: pool not initialised");
        }
    }

    function _logNextSteps(Config memory _config, Deployment memory _deployment) internal view {
        console.log("MintToLiquidityHook:", address(_deployment.hook));
        console.log("Hook salt:");
        console.logBytes32(_deployment.hookSalt);
        console.log("EverstratAMMAdapter:", address(_deployment.adapter));
        console.log("Pool id:");
        console.logBytes32(PoolId.unwrap(_deployment.poolKey.toId()));

        if (!_deployment.poolRegistered) {
            console.log("Pool NOT registered: the deployer does not own the adapter.");
            console.log("Adapter owner sends to", address(_deployment.hook), "this calldata:");
            console.logBytes(
                abi.encodeCall(
                    IMintToLiquidityHook.registerPool, (_deployment.adapter, _config.fee, _config.tickSpacing)
                )
            );
        }

        IEverstratWhitelist _whitelist = IEverstratWhitelist(_config.registry.getContractByKey(_WHITELIST_KEY));
        if (!_whitelist.isWhitelisted(address(_deployment.adapter))) {
            address[] memory _users = new address[](1);
            _users[0] = address(_deployment.adapter);
            console.log("The adapter cannot mint until the Everstrat timelock schedules, on", address(_whitelist));
            console.logBytes(abi.encodeCall(IEverstratWhitelist.addToWhitelist, (_users)));
        }
    }
}
