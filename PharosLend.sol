// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

// ═══════════════════════════════════════════════════════════════════════════
//  PharosLend v2 — Multi-Asset Lending Protocol · Pharos Testnet
//  Chain ID : 688688
//
//  Supported assets (Pharos Atlantic Testnet official addresses):
//    USDC  0xcfC8330f4BCAB529c625D12781b1C19466A9Fc8B  6 dec
//    USDT  0xE7E84B8B4f39C507499c40B4ac199B050e2882d5  6 dec
//    WBTC  0x0c64F03EEa5c30946D5c55B4b532D08ad74638a4  18 dec
//    WETH  0x7d211F77525ea39A0592794f793cC1036eEaccD5  18 dec
//    WPHRS 0x838800b758277CC111B2d48Ab01e5E164f8E9471  18 dec
//
//  Function selectors:
//    supply(address,uint256)           → 0xf2b9fdb8
//    withdraw(address,uint256)         → 0xf3fef3a3
//    borrow(address,uint256)           → 0x4b8a3529
//    repay(address,uint256)            → 0x22867d78
//    getStats()                        → 0xc59d4847
//    getPosition(address)              → 0x16c19739
//    getTokenPosition(address,address) → 0x57b7d3d5
//    getMarketData(address)            → 0xa30c302d
//    getSupportedTokens()              → 0xd3c7c2c7
// ═══════════════════════════════════════════════════════════════════════════

interface IERC20 {
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
    function transfer(address to, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
}

contract PharosLend {

    // ── Token Addresses ───────────────────────────────────────────────────
    address public constant USDC  = 0xcfC8330f4BCAB529c625D12781b1C19466A9Fc8B;
    address public constant USDT  = 0xE7E84B8B4f39C507499c40B4ac199B050e2882d5;
    address public constant WBTC  = 0x0c64F03EEa5c30946D5c55B4b532D08ad74638a4;
    address public constant WETH  = 0x7d211F77525ea39A0592794f793cC1036eEaccD5;
    address public constant WPHRS = 0x838800b758277CC111B2d48Ab01e5E164f8E9471;

    // ── Protocol Constants ────────────────────────────────────────────────
    address public owner;
    uint256 public constant LIQ_THRESHOLD_BPS = 8500; // 85 %
    uint256 public constant MAX_LTV_BPS       = 8000; // 80 %
    uint256 public constant VERSION           = 2;

    // ── Token Config ──────────────────────────────────────────────────────
    struct TokenConfig {
        bool    supported;
        uint8   decimals;      // 6 or 18
        uint256 priceUsd;      // USD price * 1e6  (e.g. $98000 → 98000_000000)
        uint256 supplyApyBps;  // basis points
        uint256 borrowAprBps;
        uint256 maxLtvBps;
    }

    mapping(address => TokenConfig) private _cfg;
    address[5] private _tokens;

    // ── Balances ──────────────────────────────────────────────────────────
    mapping(address => mapping(address => uint256)) public supplied;
    mapping(address => mapping(address => uint256)) public borrowed;
    mapping(address => uint256) public totalSupplied;
    mapping(address => uint256) public totalBorrowed;
    uint256 public txCount;

    // ── Events ────────────────────────────────────────────────────────────
    event Supplied (address indexed user, address indexed token, uint256 amount);
    event Withdrawn(address indexed user, address indexed token, uint256 amount);
    event Borrowed (address indexed user, address indexed token, uint256 amount);
    event Repaid   (address indexed user, address indexed token, uint256 amount);

    // ── Constructor (no args — paste constructor fields in Remix is N/A) ──
    constructor() {
        owner = msg.sender;

        _tokens[0] = USDC;
        _tokens[1] = USDT;
        _tokens[2] = WBTC;
        _tokens[3] = WETH;
        _tokens[4] = WPHRS;

        //                        dec   priceUsd       supplyBps borBps ltvBps
        _cfg[USDC]  = TokenConfig(true,  6, 1_000000,       520,   890,  9000);
        _cfg[USDT]  = TokenConfig(true,  6, 1_000000,       480,   820,  9000);
        _cfg[WBTC]  = TokenConfig(true, 18, 98000_000000,   150,   450,  7500);
        _cfg[WETH]  = TokenConfig(true, 18, 3200_000000,    250,   580,  8000);
        _cfg[WPHRS] = TokenConfig(true, 18, 1_000000,       800,  1400,  6500);
    }

    modifier onlySupported(address token) {
        require(_cfg[token].supported, "PharosLend: unsupported token");
        _;
    }

    // ── USD helpers ───────────────────────────────────────────────────────
    /// @dev USD value with 6-decimal precision: toUsd(1 USDC) = 1_000000 ($1.00)
    function toUsd(address token, uint256 amount) public view returns (uint256) {
        TokenConfig storage c = _cfg[token];
        return amount * c.priceUsd / (10 ** c.decimals);
    }

    function _colUsd(address user) internal view returns (uint256 t) {
        for (uint8 i = 0; i < 5; i++) {
            uint256 s = supplied[user][_tokens[i]];
            if (s > 0) t += toUsd(_tokens[i], s);
        }
    }
    function _debtUsd(address user) internal view returns (uint256 t) {
        for (uint8 i = 0; i < 5; i++) {
            uint256 b = borrowed[user][_tokens[i]];
            if (b > 0) t += toUsd(_tokens[i], b);
        }
    }

    // ── WRITE: supply ─────────────────────────────────────────────────────
    function supply(address token, uint256 amount) external onlySupported(token) {
        require(amount > 0, "zero");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "xfer fail");
        supplied[msg.sender][token] += amount;
        totalSupplied[token]        += amount;
        txCount++;
        emit Supplied(msg.sender, token, amount);
    }

    // ── WRITE: withdraw ───────────────────────────────────────────────────
    function withdraw(address token, uint256 amount) external onlySupported(token) {
        require(amount > 0, "zero");
        require(supplied[msg.sender][token] >= amount, "insufficient");
        supplied[msg.sender][token] -= amount;
        totalSupplied[token]        -= amount;
        uint256 col  = _colUsd(msg.sender);
        uint256 debt = _debtUsd(msg.sender);
        require(debt == 0 || col * LIQ_THRESHOLD_BPS / 10000 >= debt, "liq threshold");
        require(IERC20(token).transfer(msg.sender, amount), "xfer fail");
        txCount++;
        emit Withdrawn(msg.sender, token, amount);
    }

    // ── WRITE: borrow ─────────────────────────────────────────────────────
    function borrow(address token, uint256 amount) external onlySupported(token) {
        require(amount > 0, "zero");
        uint256 col     = _colUsd(msg.sender);
        uint256 debt    = _debtUsd(msg.sender);
        uint256 newDebt = debt + toUsd(token, amount);
        require(newDebt * 10000 <= col * MAX_LTV_BPS, "exceeds LTV");
        require(IERC20(token).balanceOf(address(this)) >= amount, "no liquidity");
        borrowed[msg.sender][token] += amount;
        totalBorrowed[token]        += amount;
        require(IERC20(token).transfer(msg.sender, amount), "xfer fail");
        txCount++;
        emit Borrowed(msg.sender, token, amount);
    }

    // ── WRITE: repay ──────────────────────────────────────────────────────
    function repay(address token, uint256 amount) external onlySupported(token) {
        require(amount > 0, "zero");
        require(IERC20(token).transferFrom(msg.sender, address(this), amount), "xfer fail");
        uint256 debt   = borrowed[msg.sender][token];
        uint256 repaid = amount > debt ? debt : amount;
        borrowed[msg.sender][token] -= repaid;
        totalBorrowed[token]        -= repaid;
        txCount++;
        emit Repaid(msg.sender, token, amount);
    }

    // ── READ: getPosition ─────────────────────────────────────────────────
    /// @dev Selector 0x16c19739
    /// Returns: collateralUsd, debtUsd, healthFactor (scaled *10000), availBorrowUsd
    function getPosition(address user) external view returns (
        uint256 collateralUsd,
        uint256 debtUsd,
        uint256 healthFactor,
        uint256 availableBorrowUsd
    ) {
        collateralUsd = _colUsd(user);
        debtUsd       = _debtUsd(user);
        healthFactor  = debtUsd > 0
            ? collateralUsd * LIQ_THRESHOLD_BPS / debtUsd
            : type(uint256).max;
        uint256 cap = collateralUsd * MAX_LTV_BPS / 10000;
        availableBorrowUsd = cap > debtUsd ? cap - debtUsd : 0;
    }

    // ── READ: getTokenPosition ────────────────────────────────────────────
    /// @dev Selector 0x57b7d3d5
    function getTokenPosition(address user, address token) external view returns (
        uint256 suppliedAmt, uint256 borrowedAmt,
        uint256 suppliedUsd, uint256 borrowedUsd
    ) {
        suppliedAmt = supplied[user][token];
        borrowedAmt = borrowed[user][token];
        suppliedUsd = toUsd(token, suppliedAmt);
        borrowedUsd = toUsd(token, borrowedAmt);
    }

    // ── READ: getMarketData ───────────────────────────────────────────────
    /// @dev Selector 0xa30c302d
    /// Returns: totSupAmt, totBorAmt, totSupUsd, totBorUsd,
    ///          liquidity, supplyApyBps, borrowAprBps, priceUsd, maxLtvBps
    function getMarketData(address token) external view returns (
        uint256 totSupAmt, uint256 totBorAmt,
        uint256 totSupUsd, uint256 totBorUsd,
        uint256 liquidity,
        uint256 supplyApyBps, uint256 borrowAprBps,
        uint256 priceUsd,    uint256 maxLtvBps
    ) {
        TokenConfig storage c = _cfg[token];
        totSupAmt    = totalSupplied[token];
        totBorAmt    = totalBorrowed[token];
        totSupUsd    = toUsd(token, totSupAmt);
        totBorUsd    = toUsd(token, totBorAmt);
        liquidity    = IERC20(token).balanceOf(address(this));
        supplyApyBps = c.supplyApyBps;
        borrowAprBps = c.borrowAprBps;
        priceUsd     = c.priceUsd;
        maxLtvBps    = c.maxLtvBps;
    }

    // ── READ: getStats ────────────────────────────────────────────────────
    /// @dev Selector 0xc59d4847
    /// Returns: totalSuppliedUsd, totalBorrowedUsd, txCount, utilizationBps, version
    function getStats() external view returns (
        uint256 totalSuppliedUsd, uint256 totalBorrowedUsd,
        uint256 txs, uint256 utilizationBps, uint256 version
    ) {
        for (uint8 i = 0; i < 5; i++) {
            address t = _tokens[i];
            totalSuppliedUsd += toUsd(t, totalSupplied[t]);
            totalBorrowedUsd += toUsd(t, totalBorrowed[t]);
        }
        txs            = txCount;
        utilizationBps = totalSuppliedUsd > 0 ? totalBorrowedUsd * 10000 / totalSuppliedUsd : 0;
        version        = VERSION;
    }

    // ── READ: getSupportedTokens ──────────────────────────────────────────
    /// @dev Selector 0xd3c7c2c7
    function getSupportedTokens() external view returns (address[5] memory) {
        return _tokens;
    }

    // ── ADMIN ─────────────────────────────────────────────────────────────
    function setPrice(address token, uint256 priceUsd) external {
        require(msg.sender == owner, "not owner");
        _cfg[token].priceUsd = priceUsd;
    }
    function seedLiquidity(address token, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
    }
    function emergencyWithdraw(address token, uint256 amount) external {
        require(msg.sender == owner, "not owner");
        IERC20(token).transfer(owner, amount);
    }
    function transferOwnership(address newOwner) external {
        require(msg.sender == owner, "not owner");
        require(newOwner != address(0), "zero addr");
        owner = newOwner;
    }
}
