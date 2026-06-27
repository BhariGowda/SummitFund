// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/// @title MockERC20
/// @notice Minimal, standards-compliant ERC20 used to exercise {CrowdFund}'s token mode.
/// @dev    Includes an open {mint} for test setup. Returns `true` on transfers like a
///         well-behaved token.
contract MockERC20 {
    string public name = "Mock Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;
    function setDecimals(uint8 d) external { decimals = d; }

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "ERC20: insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "ERC20: insufficient balance");
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
    }
}

/// @title FeeOnTransferERC20
/// @notice A token that burns a flat percentage on every transfer, so the recipient
///         receives less than the sender sent. Used to prove {CrowdFund} credits the
///         amount actually received rather than the amount requested.
contract FeeOnTransferERC20 {
    string public name = "Fee Token";
    string public symbol = "FEE";
    uint8 public decimals = 18;
    function setDecimals(uint8 d) external { decimals = d; }

    /// @notice Fee in basis points (1% = 100 bps) taken from each transfer.
    uint256 public immutable feeBps;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);

    constructor(uint256 _feeBps) {
        feeBps = _feeBps;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        require(allowed >= amount, "insufficient allowance");
        if (allowed != type(uint256).max) {
            allowance[from][msg.sender] = allowed - amount;
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        require(balanceOf[from] >= amount, "insufficient balance");
        uint256 fee = (amount * feeBps) / 10_000;
        uint256 net = amount - fee;
        balanceOf[from] -= amount;
        balanceOf[to] += net;
        totalSupply -= fee; // burn the fee
        emit Transfer(from, to, net);
    }
}

/// @title ReturnsFalseERC20
/// @notice A non-reverting token whose `transfer`/`transferFrom` return `false` instead
///         of throwing. Used to prove {CrowdFund} treats a `false` return as a failure.
contract ReturnsFalseERC20 {
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address, uint256) external pure returns (bool) {
        return false;
    }

    function transferFrom(address, address, uint256) external pure returns (bool) {
        return false;
    }
}
