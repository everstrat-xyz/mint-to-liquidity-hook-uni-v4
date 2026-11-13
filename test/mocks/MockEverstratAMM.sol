// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IEverstratAMM} from "interfaces/integrations/IEverstratAMM.sol";

import {MockToken} from "./MockToken.sol";

/**
 * @notice Stand-in for the Everstrat AMM that keeps its rounding: `enter` mints `floor(eth / premium)`,
 * `exit` burns `floor(requested / base)` and pays `floor(burned * base)`, queueing when it is short of ETH.
 */
contract MockEverstratAMM is IEverstratAMM {
    uint256 private constant _WAD = 1e18;
    uint256 private constant _FIRST_BATCH_ID = 1;

    MockToken public immutable EVE;

    uint256 public eveBasePriceInETH;
    uint256 public connectorWeight;
    uint256 public queuedTokens;

    error MockEverstratAMMInsufficientDeposit();
    error MockEverstratAMMTooMuchETHRequested();

    constructor(MockToken _eve, uint256 _basePrice, uint256 _connectorWeight) {
        EVE = _eve;
        eveBasePriceInETH = _basePrice;
        connectorWeight = _connectorWeight;
    }

    receive() external payable {}

    function enter(uint256 _minTokensToMint) external payable {
        uint256 _tokens = (msg.value * _WAD) / evePremiumPriceInETH();
        if (_tokens < _minTokensToMint) revert MockEverstratAMMInsufficientDeposit();

        EVE.mint(msg.sender, _tokens);
    }

    function exit(uint256 _requestedETH, uint256 _maxTokensToBurn, uint256) external returns (uint256 _batchId) {
        uint256 _tokensToBurn = (_requestedETH * _WAD) / eveBasePriceInETH;
        if (_maxTokensToBurn < _tokensToBurn) revert MockEverstratAMMTooMuchETHRequested();
        uint256 _ethToRedeem = (_tokensToBurn * eveBasePriceInETH) / _WAD;

        // Both paths pull through the allowance, as `burnFrom` and the queue escrow do.
        EVE.transferFrom(msg.sender, address(this), _tokensToBurn);
        if (address(this).balance >= _ethToRedeem) {
            EVE.burn(address(this), _tokensToBurn);
            (bool _sent,) = msg.sender.call{value: _ethToRedeem}("");
            require(_sent);
        } else {
            queuedTokens += _tokensToBurn;
            _batchId = _FIRST_BATCH_ID;
        }
    }

    function evePremiumPriceInETH() public view returns (uint256) {
        return (eveBasePriceInETH * _WAD) / connectorWeight;
    }

    function freeBalance() external view returns (uint256) {
        return address(this).balance;
    }
}
