// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title IEverstratWhitelist
 * @notice The part of the Everstrat entry whitelist the adapter depends on. `AMM.enter` checks it
 * against `msg.sender`, so the adapter has to be on it while the invite period lasts.
 * See `everstrat-xyz/contracts` (`IWhitelist`).
 */
interface IEverstratWhitelist {
    /**
     * @notice Adds addresses to the whitelist. ADMIN_ROLE only (the 48h timelock in production).
     */
    function addToWhitelist(address[] calldata _users) external;

    /**
     * @notice Removes and bans an address for the rest of the invite period. ADMIN_ROLE only.
     */
    function removeFromWhitelist(address _user) external;

    /**
     * @notice Whether `_user` may enter. True for everyone once the whitelist is disabled.
     */
    function isWhitelisted(address _user) external view returns (bool);

    /**
     * @notice Whether the invite period is over.
     */
    function disabled() external view returns (bool);
}
