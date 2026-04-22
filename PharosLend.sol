// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════
//  PharosLend — Simple Lending Protocol for Pharos Testnet
//  Chain ID : 688688
//  Tokens   : USDC (0xcfC8330f4BCAB529c625D12781b1C19466A9Fc8B)
//             USDT (0xE7E84B8B4f39C507499c40B4ac199B050e2882d5)
//
//  Function selectors (must match frontend SEL map):
//    supply(address,uint256)   → 0xf2b9fdb8
//    withdraw(address,uint256) → 0xf3fef3a3
//    borrow(address,uint256)   → 0x4b8a3529
//    repay(address,uint256)    → 0x22867d78
//    getStats()                → 0xc59d4847
//    getPosition(address)      → 0x16c19739
//    getLiquidity()            → 0x0910a510
// ═══════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PharosLend {

    // ── Config ────────────────────────────────────────────────────────────
    address public owner;
    address public immutable USDC;
    address public immutable USDT;

    uint256 public constant SUPPLY_APY_BPS  = 520;   // 5.20 %
    uint256 public constant BORROW_APR_BPS  = 890;   // 8.90 %
    uint256 public constant MAX_LTV         = 80;    // 80 %  max borrow ratio
    uint256 public constant LIQ_THRESHOLD   = 85;    // 85 %  liquidation threshold
    uint256 public constant VERSION         = 1;

    // ── State ─────────────────────────────────────────────────────────────
    struct Position {
        uint256 suppliedUsdc;   // 6-decimal units
        uint256 suppliedUsdt;   // 6-decimal units
        uint256 borrowedUsdc;
        uint256 borrowedUsdt;
        uint256 maxBorrow;      // cached max borrow capacity
        uint256 lastUpdate;     // block.timestamp of last action
        bool    hasPosition;
    }

    mapping(address => Position) private _positions;

    uint256 public totalSuppliedUsdc;
    uint256 public totalSuppliedUsdt;
    uint256 public totalBorrowedUsdc;
    uint256 public totalBorrowedUsdt;
    uint256 public txCount;             // used as "totalDepositors" proxy in getStats

    // ── Events ────────────────────────────────────────────────────────────
    event Supplied(address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed(address indexed user, address indexed token, uint256 amount);
    event Repaid(address indexed user, address indexed token, uint256 amount);

    // ── Constructor ───────────────────────────────────────────────────────
    constructor(address _usdc, address _usdt) {
        owner = msg.sender;
        USDC  = _usdc;
        USDT  = _usdt;
    }

    modifier onlyValidToken(address token) {
        require(token == USDC || token == USDT, "PharosLend: invalid token");
        _;
    }

    // ── WRITE: supply ─────────────────────────────────────────────────────
    /// @notice Supply USDC or USDT as collateral and earn interest.
    /// @dev Selector: 0xf2b9fdb8
    function supply(address token, uint256 amount) external onlyValidToken(token) {
        require(amount > 0, "PharosLend: amount is zero");

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(ok, "PharosLend: transferFrom failed");

        Position storage p = _positions[msg.sender];
        p.hasPosition = true;
        p.lastUpdate  = block.timestamp;

        if (token == USDC) {
            p.suppliedUsdc    += amount;
            totalSuppliedUsdc += amount;
        } else {
            p.suppliedUsdt    += amount;
            totalSuppliedUsdt += amount;
        }

        _refreshMaxBorrow(p);
        txCount++;
        emit Supplied(msg.sender, token, amount);
    }

    // ── WRITE: withdraw ───────────────────────────────────────────────────
    /// @notice Withdraw previously supplied tokens.
    /// @dev Selector: 0xf3fef3a3
    function withdraw(address token, uint256 amount) external onlyValidToken(token) {
        require(amount > 0, "PharosLend: amount is zero");
        Position storage p = _positions[msg.sender];

        if (token == USDC) {
            require(p.suppliedUsdc >= amount, "PharosLend: insufficient supplied USDC");
            p.suppliedUsdc    -= amount;
            totalSuppliedUsdc -= amount;
        } else {
            require(p.suppliedUsdt >= amount, "PharosLend: insufficient supplied USDT");
            p.suppliedUsdt    -= amount;
            totalSuppliedUsdt -= amount;
        }

        // Ensure remaining collateral still covers outstanding debt
        uint256 collateral = p.suppliedUsdc + p.suppliedUsdt;
        uint256 debt       = p.borrowedUsdc + p.borrowedUsdt;
        require(
            debt == 0 || collateral * LIQ_THRESHOLD / 100 >= debt,
            "PharosLend: would fall below liquidation threshold"
        );

        _refreshMaxBorrow(p);
        p.lastUpdate = block.timestamp;

        bool ok = IERC20(token).transfer(msg.sender, amount);
        require(ok, "PharosLend: transfer failed");

        txCount++;
        emit Withdrawn(msg.sender, token, amount);
    }

    // ── WRITE: borrow ─────────────────────────────────────────────────────
    /// @notice Borrow tokens against supplied collateral (max 80 % LTV).
    /// @dev Selector: 0x4b8a3529
    function borrow(address token, uint256 amount) external onlyValidToken(token) {
        require(amount > 0, "PharosLend: amount is zero");
        Position storage p = _positions[msg.sender];

        uint256 collateral = p.suppliedUsdc + p.suppliedUsdt;
        uint256 debt       = p.borrowedUsdc + p.borrowedUsdt;
        require(debt + amount <= collateral * MAX_LTV / 100, "PharosLend: exceeds max LTV");

        uint256 available = IERC20(token).balanceOf(address(this));
        require(available >= amount, "PharosLend: insufficient protocol liquidity");

        if (token == USDC) {
            p.borrowedUsdc    += amount;
            totalBorrowedUsdc += amount;
        } else {
            p.borrowedUsdt    += amount;
            totalBorrowedUsdt += amount;
        }

        _refreshMaxBorrow(p);
        p.lastUpdate = block.timestamp;

        bool ok = IERC20(token).transfer(msg.sender, amount);
        require(ok, "PharosLend: transfer failed");

        txCount++;
        emit Borrowed(msg.sender, token, amount);
    }

    // ── WRITE: repay ──────────────────────────────────────────────────────
    /// @notice Repay borrowed tokens.
    /// @dev Selector: 0x22867d78
    function repay(address token, uint256 amount) external onlyValidToken(token) {
        require(amount > 0, "PharosLend: amount is zero");
        Position storage p = _positions[msg.sender];

        bool ok = IERC20(token).transferFrom(msg.sender, address(this), amount);
        require(ok, "PharosLend: transferFrom failed");

        if (token == USDC) {
            uint256 repaid    = amount > p.borrowedUsdc ? p.borrowedUsdc : amount;
            p.borrowedUsdc    -= repaid;
            totalBorrowedUsdc -= repaid;
        } else {
            uint256 repaid    = amount > p.borrowedUsdt ? p.borrowedUsdt : amount;
            p.borrowedUsdt    -= repaid;
            totalBorrowedUsdt -= repaid;
        }

        _refreshMaxBorrow(p);
        p.lastUpdate = block.timestamp;
        txCount++;
        emit Repaid(msg.sender, token, amount);
    }

    // ── READ: getPosition ─────────────────────────────────────────────────
    /// @notice Returns full position data for a user.
    /// @dev Selector: 0x16c19739
    ///      Return layout must match frontend ABI parser:
    ///      [0] suppliedUsdc  [1] suppliedUsdt  [2] borrowedUsdc
    ///      [3] borrowedUsdt  [4] maxBorrow      [5] lastUpdate  [6] hasPosition
    function getPosition(address user) external view returns (
        uint256 suppliedUsdc,
        uint256 suppliedUsdt,
        uint256 borrowedUsdc,
        uint256 borrowedUsdt,
        uint256 maxBorrow,
        uint256 lastUpdate,
        bool    hasPosition
    ) {
        Position storage p = _positions[user];
        return (
            p.suppliedUsdc,
            p.suppliedUsdt,
            p.borrowedUsdc,
            p.borrowedUsdt,
            p.maxBorrow,
            p.lastUpdate,
            p.hasPosition
        );
    }

    // ── READ: getStats ────────────────────────────────────────────────────
    /// @notice Protocol-level stats.
    /// @dev Selector: 0xc59d4847
    ///      Return layout: [0] totalSupplied  [1] totalBorrowed
    ///                     [2] txCount        [3] utilization
    ///                     [4] supplyApy      [5] version
    function getStats() external view returns (
        uint256 totalSupplied,
        uint256 totalBorrowed,
        uint256 depositors,
        uint256 utilization,
        uint256 supplyApy,
        uint256 version
    ) {
        uint256 ts = totalSuppliedUsdc + totalSuppliedUsdt;
        uint256 tb = totalBorrowedUsdc + totalBorrowedUsdt;
        return (
            ts,
            tb,
            txCount,
            ts > 0 ? tb * 100 / ts : 0,
            SUPPLY_APY_BPS,
            VERSION
        );
    }

    // ── READ: getLiquidity ────────────────────────────────────────────────
    /// @notice Available protocol liquidity per token.
    /// @dev Selector: 0x0910a510
    function getLiquidity() external view returns (uint256 usdcLiq, uint256 usdtLiq) {
        return (
            IERC20(USDC).balanceOf(address(this)),
            IERC20(USDT).balanceOf(address(this))
        );
    }

    // ── INTERNAL ──────────────────────────────────────────────────────────
    function _refreshMaxBorrow(Position storage p) internal {
        uint256 col  = p.suppliedUsdc + p.suppliedUsdt;
        uint256 debt = p.borrowedUsdc + p.borrowedUsdt;
        uint256 cap  = col * MAX_LTV / 100;
        p.maxBorrow  = cap > debt ? cap - debt : 0;
    }

    // ── ADMIN ─────────────────────────────────────────────────────────────
    /// @notice Emergency token recovery (owner only).
    function emergencyWithdraw(address token, uint256 amount) external {
        require(msg.sender == owner, "PharosLend: not owner");
        IERC20(token).transfer(owner, amount);
    }

    /// @notice Transfer contract ownership.
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "PharosLend: not owner");
        require(newOwner != address(0), "PharosLend: zero address");
        owner = newOwner;
    }

    /// @notice Seed protocol liquidity (owner deposits tokens so users can borrow).
    /// @dev Call this after deploying: approve contract, then call seedLiquidity.
    function seedLiquidity(address token, uint256 amount) external {
        require(msg.sender == owner, "PharosLend: not owner");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
}
