// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IIssuerAdapter} from "interfaces/IIssuerAdapter.sol";

/**
 * @title IEverstratAMMAdapter
 * @notice Events and errors of the Everstrat issuer adapter.
 */
interface IEverstratAMMAdapter is IIssuerAdapter {
    /**
     * @notice The address that receives the hook's profit changed.
     */
    event BeneficiaryChanged(address indexed previous, address indexed current);

    error EverstratAMMAdapterZeroAddress();
    error EverstratAMMAdapterCallerNotHook();
    error EverstratAMMAdapterValueMismatch();
    error EverstratAMMAdapterUnexpectedETH();
    error EverstratAMMAdapterQueuedExit(uint256 batchId);
    error EverstratAMMAdapterInsufficientOutput();

    /**
     * @notice Sets the address that receives the hook's profit. Owner only.
     */
    function setBeneficiary(address _beneficiary) external;
}
