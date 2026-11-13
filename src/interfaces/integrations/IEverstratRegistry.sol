// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IEverstratRegistry
 * @notice The part of the Everstrat Registry the deploy script and fork tests read.
 * See `everstrat-xyz/contracts` (`Registry`, `Auth`).
 */
interface IEverstratRegistry {
    /**
     * @notice The protocol contract registered under `_key`, e.g. `keccak256("AMM")`.
     */
    function getContractByKey(bytes32 _key) external view returns (address);

    /**
     * @notice The `_index`-th holder of `_role`, e.g. `keccak256("ADMIN_ROLE")`.
     */
    function getRoleMember(bytes32 _role, uint256 _index) external view returns (address);
}
