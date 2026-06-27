// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "./IERC20.sol";

/// @title EverestOrBust
/// @author Bhari Gowda
/// @notice Multi-stablecoin fundraise for the Everest summit attempt, 2027.
///         $69,000 goal. 69-day campaign (Jan 1 - Mar 10 2027).
///         Accepts USDC, USDT, and DAI. No price oracle needed.
///         Each address may contribute at most $69 total across all tokens.
///         If the goal is not reached, contributors may refund in full.
///         If the goal is exceeded, contributors may redeem their pro-rata excess.
/// @dev    All internal accounting uses 18-decimal normalized units.
///         USDC and USDT (6 decimals) are scaled up by 1e12 on ingress
///         and scaled back down on egress. DAI (18 decimals) passes through.
contract EverestOrBust {
    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum contribution per address, normalized to 18 decimals ($69)
    uint256 public constant CAP_PER_ADDRESS = 69e18;
    /// @notice Funding goal, normalized to 18 decimals ($69,000)
    uint256 public constant GOAL = 69_000e18;
    /// @notice Campaign duration in days
    uint256 public constant DURATION_DAYS = 69;
    /// @notice Scale factor for 6-decimal tokens (USDC, USDT)
    uint256 private constant SCALE_6 = 1e12;

    /*//////////////////////////////////////////////////////////////
                          REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/

    uint256 private _locked = 1;

    modifier nonReentrant() {
        if (_locked != 1) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error Reentrancy();
    error NotCreator();
    error CampaignNotStarted();
    error CampaignEnded();
    error CampaignNotEnded();
    error GoalNotReached();
    error GoalReached();
    error AlreadyWithdrawn();
    error UnsupportedToken();
    error ZeroAmount();
    error CapExceeded();
    error NothingToRefund();
    error NothingToRedeem();
    error TokenTransferFailed();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event Contributed(address indexed contributor, address indexed token, uint256 amount, uint256 normalized);
    event Withdrawn(address indexed creator, uint256 usdc, uint256 usdt, uint256 dai);
    event Refunded(address indexed contributor, uint256 usdc, uint256 usdt, uint256 dai);
    event ExcessRedeemed(address indexed contributor, uint256 usdc, uint256 usdt, uint256 dai);

    /*//////////////////////////////////////////////////////////////
                            STATE VARIABLES
    //////////////////////////////////////////////////////////////*/

    address public immutable creator;
    uint256 public immutable start;
    uint256 public immutable deadline;

    address public immutable USDC;
    address public immutable USDT;
    address public immutable DAI;

    /// @notice Total raised across all tokens, normalized to 18 decimals
    uint256 public totalRaisedNormalized;

    /// @notice Per-contributor total contributed, normalized
    mapping(address => uint256) public contributedNormalized;

    /// @notice Per-contributor raw token contributions (native decimals)
    mapping(address => uint256) public contributedUSDC;
    mapping(address => uint256) public contributedUSDT;
    mapping(address => uint256) public contributedDAI;

    bool public withdrawn;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _creator Address entitled to withdraw if goal is met
    /// @param _usdc    USDC token address
    /// @param _usdt    USDT token address
    /// @param _dai     DAI token address
    /// @param _start   Campaign start timestamp (Jan 1 2027 = 1767225600)
    constructor(address _creator, address _usdc, address _usdt, address _dai, uint256 _start) {
        creator = _creator;
        USDC = _usdc;
        USDT = _usdt;
        DAI = _dai;
        start = _start;
        deadline = _start + (DURATION_DAYS * 1 days);
    }

    /*//////////////////////////////////////////////////////////////
                            CONTRIBUTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Contribute `amount` of `token` to the campaign.
    /// @dev Caller must approve this contract first.
    ///      Excess above the $69 per-address cap is automatically rejected —
    ///      only the capped amount is pulled.
    /// @param token  USDC, USDT, or DAI address
    /// @param amount Amount in the token's native decimals
    function contribute(address token, uint256 amount) external nonReentrant {
        if (block.timestamp < start) revert CampaignNotStarted();
        if (block.timestamp > deadline) revert CampaignEnded();
        if (amount == 0) revert ZeroAmount();
        if (contributedNormalized[msg.sender] >= CAP_PER_ADDRESS) revert CapExceeded();

        uint256 normalized = _normalize(token, amount);
        uint256 remaining = CAP_PER_ADDRESS - contributedNormalized[msg.sender];

        // cap to remaining allowance
        if (normalized > remaining) {
            normalized = remaining;
            amount = _denormalize(token, normalized);
        }

        _pullToken(token, msg.sender, address(this), amount);

        contributedNormalized[msg.sender] += normalized;
        totalRaisedNormalized += normalized;

        if (token == USDC) contributedUSDC[msg.sender] += amount;
        else if (token == USDT) contributedUSDT[msg.sender] += amount;
        else contributedDAI[msg.sender] += amount;

        emit Contributed(msg.sender, token, amount, normalized);
    }

    /*//////////////////////////////////////////////////////////////
                              WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Withdraw all funds to the creator after a successful campaign.
    function withdraw() external nonReentrant {
        if (msg.sender != creator) revert NotCreator();
        if (block.timestamp <= deadline) revert CampaignNotEnded();
        if (totalRaisedNormalized < GOAL) revert GoalNotReached();
        if (withdrawn) revert AlreadyWithdrawn();
        withdrawn = true;

        uint256 usdcBal = IERC20(USDC).balanceOf(address(this));
        uint256 usdtBal = IERC20(USDT).balanceOf(address(this));
        uint256 daiBal = IERC20(DAI).balanceOf(address(this));

        if (usdcBal > 0) _sendToken(USDC, creator, usdcBal);
        if (usdtBal > 0) _sendToken(USDT, creator, usdtBal);
        if (daiBal > 0) _sendToken(DAI, creator, daiBal);

        emit Withdrawn(creator, usdcBal, usdtBal, daiBal);
    }

    /*//////////////////////////////////////////////////////////////
                               REFUND
    //////////////////////////////////////////////////////////////*/

    /// @notice Reclaim full contribution if the goal was not met by deadline.
    function refund() external nonReentrant {
        if (block.timestamp <= deadline) revert CampaignNotEnded();
        if (totalRaisedNormalized >= GOAL) revert GoalReached();

        uint256 usdcAmt = contributedUSDC[msg.sender];
        uint256 usdtAmt = contributedUSDT[msg.sender];
        uint256 daiAmt = contributedDAI[msg.sender];
        if (usdcAmt == 0 && usdtAmt == 0 && daiAmt == 0) revert NothingToRefund();

        contributedUSDC[msg.sender] = 0;
        contributedUSDT[msg.sender] = 0;
        contributedDAI[msg.sender] = 0;
        contributedNormalized[msg.sender] = 0;

        if (usdcAmt > 0) _sendToken(USDC, msg.sender, usdcAmt);
        if (usdtAmt > 0) _sendToken(USDT, msg.sender, usdtAmt);
        if (daiAmt > 0) _sendToken(DAI, msg.sender, daiAmt);

        emit Refunded(msg.sender, usdcAmt, usdtAmt, daiAmt);
    }

    /*//////////////////////////////////////////////////////////////
                          EXCESS REDEMPTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Redeem pro-rata share of excess if campaign was overfunded.
    /// @dev Pro-rata excess is computed per-token based on each token's share
    ///      of the total contract balance relative to the contributor's normalized share.
    function redeemExcess() external nonReentrant {
        if (block.timestamp <= deadline) revert CampaignNotEnded();
        if (totalRaisedNormalized <= GOAL) revert NothingToRedeem();

        uint256 myContrib = contributedNormalized[msg.sender];
        if (myContrib == 0) revert NothingToRedeem();

        uint256 excessNormalized = totalRaisedNormalized - GOAL;
        uint256 myExcessNormalized = (myContrib * excessNormalized) / totalRaisedNormalized;
        if (myExcessNormalized == 0) revert NothingToRedeem();

        // distribute excess proportionally across token balances
        uint256 usdcBal = IERC20(USDC).balanceOf(address(this));
        uint256 usdtBal = IERC20(USDT).balanceOf(address(this));
        uint256 daiBal = IERC20(DAI).balanceOf(address(this));

        // total contract balance in normalized units
        uint256 totalBalNormalized = (usdcBal * SCALE_6) + (usdtBal * SCALE_6) + daiBal;

        uint256 usdcExcess = totalBalNormalized > 0 ? (usdcBal * myExcessNormalized) / totalBalNormalized : 0;
        uint256 usdtExcess = totalBalNormalized > 0 ? (usdtBal * myExcessNormalized) / totalBalNormalized : 0;
        uint256 daiExcess  = totalBalNormalized > 0 ? (daiBal  * myExcessNormalized) / totalBalNormalized : 0;

        // reduce contributor's normalized balance
        contributedNormalized[msg.sender] = myContrib - myExcessNormalized;

        if (usdcExcess > 0) _sendToken(USDC, msg.sender, usdcExcess);
        if (usdtExcess > 0) _sendToken(USDT, msg.sender, usdtExcess);
        if (daiExcess > 0)  _sendToken(DAI,  msg.sender, daiExcess);

        emit ExcessRedeemed(msg.sender, usdcExcess, usdtExcess, daiExcess);
    }

    /*//////////////////////////////////////////////////////////////
                             VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice True if the campaign is currently accepting contributions
    function isActive() external view returns (bool) {
        return block.timestamp >= start && block.timestamp <= deadline;
    }

    /// @notice Normalized USD amount still needed to reach the goal
    function remaining() external view returns (uint256) {
        if (totalRaisedNormalized >= GOAL) return 0;
        return GOAL - totalRaisedNormalized;
    }

    /// @notice Remaining contribution allowance for `contributor` in normalized USD
    function remainingCap(address contributor) external view returns (uint256) {
        uint256 contrib = contributedNormalized[contributor];
        if (contrib >= CAP_PER_ADDRESS) return 0;
        return CAP_PER_ADDRESS - contrib;
    }

    /*//////////////////////////////////////////////////////////////
                           INTERNAL HELPERS
    //////////////////////////////////////////////////////////////*/

    function _normalize(address token, uint256 amount) internal view returns (uint256) {
        if (token == USDC || token == USDT) return amount * SCALE_6;
        if (token == DAI) return amount;
        revert UnsupportedToken();
    }

    function _denormalize(address token, uint256 normalized) internal view returns (uint256) {
        if (token == USDC || token == USDT) return normalized / SCALE_6;
        if (token == DAI) return normalized;
        revert UnsupportedToken();
    }

    function _pullToken(address token, address from, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(IERC20.transferFrom.selector, from, to, amount)
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }

    function _sendToken(address token, address to, uint256 amount) internal {
        (bool ok, bytes memory ret) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!ok || (ret.length != 0 && !abi.decode(ret, (bool)))) revert TokenTransferFailed();
    }
}
