// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BeforeSwapDelta} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";

import {IIssuerAdapter} from "interfaces/IIssuerAdapter.sol";

/**
 * @title IMintToLiquidityHook
 * @notice Structs, events, errors and external surface of the Mint-to-Liquidity hook.
 */
interface IMintToLiquidityHook {
    /*//////////////////////////////////////////////////////////////
                                STRUCTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice What the hook stores per registered pool.
     * @param adapter The issuer adapter the pool is bound to.
     * @param tokenIsCurrency0 Whether the issuer's token is the pool's `currency0`.
     */
    struct PoolConfig {
        IIssuerAdapter adapter;
        bool tokenIsCurrency0;
    }

    /**
     * @notice The issuer's band, in price and in pool terms.
     * @param ceiling Mint price, quote per token, WAD.
     * @param floor Redemption price, quote per token, WAD. Equals `ceiling` for a single-price issuer.
     * @param sqrtCeilingX96 `ceiling` as a pool sqrtPrice.
     * @param sqrtFloorX96 `floor` as a pool sqrtPrice.
     */
    struct Band {
        uint256 ceiling;
        uint256 floor;
        uint160 sqrtCeilingX96;
        uint160 sqrtFloorX96;
    }

    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice A pool was bound to an issuer adapter and initialised at the band's midpoint.
     */
    event PoolRegistered(
        PoolId indexed poolId, IIssuerAdapter indexed adapter, bool tokenIsCurrency0, uint160 sqrtPriceX96
    );

    /**
     * @notice The hook filled a swap straight from the issuer.
     * @param isBuy True for a mint at the ceiling, false for a redemption at the floor.
     * @param tokens Tokens the swapper received (buy) or paid (sell).
     * @param quote Quote the swapper paid (buy) or received (sell).
     * @param price The band edge the fill was priced at, WAD.
     */
    event DirectFilled(PoolId indexed poolId, bool isBuy, uint256 tokens, uint256 quote, uint256 price);

    /**
     * @notice The hook traded the pool price back to a band edge.
     * @param fromAbove True when the price was above the ceiling, false when below the floor.
     * @param tokens Tokens minted (from above) or redeemed (from below).
     * @param quote Quote the pool paid (from above) or was paid (from below).
     * @param profit Quote sent to the beneficiary.
     */
    event Rebalanced(PoolId indexed poolId, bool fromAbove, uint256 tokens, uint256 quote, uint256 profit);

    /**
     * @notice A rebalance reverted and was unwound; the user's swap carried on without it.
     */
    event RebalanceSkipped(PoolId indexed poolId, bytes reason);

    /**
     * @notice A direct fill reverted and was unwound; the swap fell through to the curve.
     */
    event DirectFillSkipped(PoolId indexed poolId, bytes reason);

    /**
     * @notice The issuer's band could not be used, so the hook stands aside for this transaction.
     */
    event BandInvalidated(PoolId indexed poolId, uint256 ceiling, uint256 floor);

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error MintToLiquidityHookZeroAddress();
    error MintToLiquidityHookNotAdapterOwner();
    error MintToLiquidityHookInvalidCurrencies();
    error MintToLiquidityHookDynamicFeeNotSupported();
    error MintToLiquidityHookPoolAlreadyRegistered();
    error MintToLiquidityHookPoolNotRegistered();
    error MintToLiquidityHookInvalidBand();
    error MintToLiquidityHookCallerNotSelf();
    error MintToLiquidityHookUnprofitableRebalance();
    error MintToLiquidityHookNoExitCapacity();
    error MintToLiquidityHookNothingToFill();

    /*//////////////////////////////////////////////////////////////
                               FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /**
     * @notice Quote base units a sell is priced below the floor, to absorb an issuer rounding twice.
     */
    function ROUNDING_SLACK() external view returns (uint256);

    /**
     * @notice Binds a new pool to `_adapter` and initialises it at the band's midpoint.
     * @dev Only the adapter's owner can call it. The key pairs `adapter.token()` with
     * `adapter.quoteCurrency()` and uses this hook.
     * @param _adapter The issuer adapter.
     * @param _fee The pool's static LP fee, in pips.
     * @param _tickSpacing The pool's tick spacing.
     * @return _key The key of the pool that was initialised.
     */
    function registerPool(IIssuerAdapter _adapter, uint24 _fee, int24 _tickSpacing)
        external
        returns (PoolKey memory _key);

    /**
     * @notice Moves the pool price back to the nearest band edge. Anyone can call it.
     * @dev Unlike the rebalances inside a swap, this one reverts when the issuer does.
     * @param _key The pool to rebalance.
     * @return _ran False when the price was already inside the band.
     */
    function rebalance(PoolKey calldata _key) external returns (bool _ran);

    /**
     * @notice Self-call target that lets a failed rebalance unwind without reverting the swap.
     */
    function rebalanceInternal(PoolKey calldata _key) external;

    /**
     * @notice Self-call target that lets a failed direct fill unwind without reverting the swap.
     */
    function fillInternal(PoolKey calldata _key, SwapParams calldata _params) external returns (BeforeSwapDelta _delta);

    /**
     * @notice The configuration of a registered pool (zero adapter when unregistered).
     */
    function poolConfig(PoolId _poolId) external view returns (PoolConfig memory);

    /**
     * @notice Reads the pool's band from its adapter. Uncached; for integrators and tests.
     * @return _valid False when the hook would stand aside.
     * @return _band The band, meaningful only when `_valid`.
     */
    function getBand(PoolId _poolId) external view returns (bool _valid, Band memory _band);
}
