// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Address} from "@openzeppelin/contracts/utils/Address.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";

import {IEverstratAMMAdapter} from "interfaces/adapters/IEverstratAMMAdapter.sol";
import {IIssuerAdapter} from "interfaces/IIssuerAdapter.sol";
import {IEverstratAMM} from "interfaces/integrations/IEverstratAMM.sol";

/**
 * @title EverstratAMMAdapter
 * @notice Plugs the Everstrat AMM into the Mint-to-Liquidity hook: EVE mints at the premium price
 * (ceiling) and redeems at the base price (floor), both against native ETH.
 *
 * @dev The adapter is an ordinary AMM user and has to be on the Everstrat whitelist to mint. Only
 * the hook can mint or redeem through it; otherwise it would let anyone past that whitelist.
 */
contract EverstratAMMAdapter is IEverstratAMMAdapter, Ownable {
    using SafeERC20 for IERC20;
    using Address for address payable;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    uint256 private constant _WAD = 1e18;

    /// @dev A queued exit is rejected outright, so its slippage tolerance is never used.
    uint256 private constant _NO_PRICE_TOLERANCE = 0;

    IEverstratAMM public immutable AMM;
    IERC20 public immutable EVE;
    address public immutable HOOK;

    /*//////////////////////////////////////////////////////////////
                            STORAGE VARIABLES
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIssuerAdapter
    address public beneficiary;

    /*//////////////////////////////////////////////////////////////
                               MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyHook() {
        if (msg.sender != HOOK) revert EverstratAMMAdapterCallerNotHook();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor(IEverstratAMM _amm, IERC20 _eve, address _hook, address _owner, address _beneficiary) Ownable(_owner) {
        if (address(_amm) == address(0) || address(_eve) == address(0) || _hook == address(0)) {
            revert EverstratAMMAdapterZeroAddress();
        }

        AMM = _amm;
        EVE = _eve;
        HOOK = _hook;
        _setBeneficiary(_beneficiary);
    }

    /**
     * @notice Receives the ETH of a redemption. Only the AMM pays the adapter.
     */
    receive() external payable {
        if (msg.sender != address(AMM)) revert EverstratAMMAdapterUnexpectedETH();
    }

    /*//////////////////////////////////////////////////////////////
                             HOOK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIssuerAdapter
    function mint(uint256 _quoteIn, uint256 _minTokens) external payable onlyHook returns (uint256 _tokensOut) {
        if (msg.value != _quoteIn) revert EverstratAMMAdapterValueMismatch();

        AMM.enter{value: _quoteIn}(_minTokens);

        _tokensOut = EVE.balanceOf(address(this));
        EVE.safeTransfer(HOOK, _tokensOut);
    }

    /// @inheritdoc IIssuerAdapter
    function redeem(uint256 _tokens, uint256 _minQuote) external onlyHook returns (uint256 _quoteOut) {
        EVE.safeTransferFrom(HOOK, address(this), _tokens);

        // `exit` is sized in ETH: it burns `floor(requested / price)` EVE and pays `floor(burned * price)`,
        // so it can leave a little EVE unburned and pay less than requested: one wei less at most while
        // one EVE is worth no more than one ETH, which the hook's `ROUNDING_SLACK` absorbs.
        uint256 _requestedETH = Math.mulDiv(_tokens, AMM.eveBasePriceInETH(), _WAD);
        uint256 _balanceBefore = address(this).balance;

        EVE.forceApprove(address(AMM), _tokens);
        uint256 _batchId = AMM.exit(_requestedETH, _tokens, _NO_PRICE_TOLERANCE);
        // A non-zero batch id means the AMM queued the exit. Reverting unwinds the queue entry.
        if (_batchId != 0) revert EverstratAMMAdapterQueuedExit(_batchId);
        EVE.forceApprove(address(AMM), 0);

        _quoteOut = address(this).balance - _balanceBefore;
        if (_quoteOut < _minQuote) revert EverstratAMMAdapterInsufficientOutput();

        // Unburned EVE goes back with the ETH; the hook sweeps it to the beneficiary.
        uint256 _unburned = EVE.balanceOf(address(this));
        if (_unburned != 0) EVE.safeTransfer(HOOK, _unburned);

        payable(HOOK).sendValue(_quoteOut);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IEverstratAMMAdapter
    function setBeneficiary(address _beneficiary) external onlyOwner {
        _setBeneficiary(_beneficiary);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc IIssuerAdapter
    function token() external view returns (IERC20) {
        return EVE;
    }

    /// @inheritdoc IIssuerAdapter
    function quoteCurrency() external pure returns (Currency) {
        return Currency.wrap(address(0));
    }

    /// @inheritdoc IIssuerAdapter
    function mintPrice() external view returns (uint256) {
        return AMM.evePremiumPriceInETH();
    }

    /// @inheritdoc IIssuerAdapter
    function redeemPrice() external view returns (uint256) {
        return AMM.eveBasePriceInETH();
    }

    /// @inheritdoc IIssuerAdapter
    function maxRedeemNow() external view returns (uint256) {
        return AMM.freeBalance();
    }

    /// @inheritdoc IIssuerAdapter
    function owner() public view override(Ownable, IIssuerAdapter) returns (address) {
        return Ownable.owner();
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _setBeneficiary(address _beneficiary) internal {
        if (_beneficiary == address(0)) revert EverstratAMMAdapterZeroAddress();

        emit BeneficiaryChanged(beneficiary, _beneficiary);
        beneficiary = _beneficiary;
    }
}
