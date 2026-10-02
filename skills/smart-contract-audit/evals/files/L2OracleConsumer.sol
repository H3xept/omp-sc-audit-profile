// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

interface IERC20 {
    function transfer(address, uint256) external returns (bool);
    function transferFrom(address, address, uint256) external returns (bool);
    function decimals() external view returns (uint8);
}

interface AggregatorV3Interface {
    function decimals() external view returns (uint8);
    function latestRoundData()
        external
        view
        returns (uint80 roundId, int256 answer, uint256 startedAt, uint256 updatedAt, uint80 answeredInRound);
}

/// @notice Isolated-collateral lending market deployed on Arbitrum One. Each (user, collateral token)
/// position borrows the 18-decimal USD stablecoin `debtToken`. Collateral is priced with Chainlink USD feeds.
contract L2OracleConsumer {
    struct Asset {
        AggregatorV3Interface feed;
        uint8 tokenDecimals;
        bool listed;
    }

    struct Position {
        uint256 collateral;
        uint256 scaledDebt;
    }

    uint256 public constant STALENESS_THRESHOLD = 1 hours;
    uint256 public constant LTV_BPS = 8_000;
    uint256 public constant LIQ_THRESHOLD_BPS = 8_500;
    uint256 public constant LIQ_BONUS_BPS = 500;
    uint256 public constant BORROW_RATE_PER_YEAR = 0.05e18; // 5% APR
    uint256 public constant BLOCKS_PER_YEAR = 126_144_000; // Arbitrum One: ~0.25s blocks

    address public immutable owner;
    IERC20 public immutable debtToken;

    uint256 public borrowIndex = 1e18;
    uint256 public lastAccrualBlock;

    mapping(address => Asset) public assets;
    mapping(address => mapping(address => Position)) public positions;

    constructor(IERC20 _debtToken) {
        owner = msg.sender;
        debtToken = _debtToken;
        lastAccrualBlock = block.number;
    }

    /// @param feed e.g. ETH/USD, USDC/USD, wstETH/ETH — whichever Chainlink feed exists for the token.
    function listAsset(address token, AggregatorV3Interface feed) external {
        require(msg.sender == owner, "not owner");
        assets[token] = Asset(feed, IERC20(token).decimals(), true);
    }

    /// @return price USD per whole token, 8 decimals
    function getPrice(address token) public view returns (uint256) {
        Asset memory a = assets[token];
        require(a.listed, "unlisted");
        (uint80 roundId, int256 answer,, uint256 updatedAt, uint80 answeredInRound) = a.feed.latestRoundData();
        require(answer > 0, "bad price");
        require(answeredInRound >= roundId, "stale round");
        require(block.timestamp - updatedAt <= STALENESS_THRESHOLD, "stale price");
        return uint256(answer);
    }

    /// @return value collateral value in 18-decimal USD
    function collateralValue(address user, address token) public view returns (uint256) {
        return positions[user][token].collateral * getPrice(token) * 1e10 / (10 ** assets[token].tokenDecimals);
    }

    function debtOf(address user, address token) public view returns (uint256) {
        return positions[user][token].scaledDebt * _currentIndex() / 1e18;
    }

    function accrue() public {
        borrowIndex = _currentIndex();
        lastAccrualBlock = block.number;
    }

    function deposit(address token, uint256 amount) external {
        require(assets[token].listed, "unlisted");
        IERC20(token).transferFrom(msg.sender, address(this), amount);
        positions[msg.sender][token].collateral += amount;
    }

    function borrow(address token, uint256 amount) external {
        accrue();
        Position storage p = positions[msg.sender][token];
        p.scaledDebt += amount * 1e18 / borrowIndex;
        require(debtOf(msg.sender, token) * 10_000 <= collateralValue(msg.sender, token) * LTV_BPS, "ltv");
        debtToken.transfer(msg.sender, amount);
    }

    function repay(address token, uint256 amount) external {
        accrue();
        debtToken.transferFrom(msg.sender, address(this), amount);
        positions[msg.sender][token].scaledDebt -= amount * 1e18 / borrowIndex;
    }

    function withdraw(address token, uint256 amount) external {
        accrue();
        Position storage p = positions[msg.sender][token];
        p.collateral -= amount;
        require(debtOf(msg.sender, token) * 10_000 <= collateralValue(msg.sender, token) * LTV_BPS, "ltv");
        IERC20(token).transfer(msg.sender, amount);
    }

    function liquidate(address user, address token, uint256 repayAmount) external {
        accrue();
        Position storage p = positions[user][token];
        uint256 debt = debtOf(user, token);
        require(debt * 10_000 > collateralValue(user, token) * LIQ_THRESHOLD_BPS, "healthy");
        require(repayAmount <= debt, "too much");

        debtToken.transferFrom(msg.sender, address(this), repayAmount);
        p.scaledDebt -= repayAmount * 1e18 / borrowIndex;

        uint256 seize = repayAmount * (10 ** assets[token].tokenDecimals) * (10_000 + LIQ_BONUS_BPS)
            / (getPrice(token) * 1e10 * 10_000);
        if (seize > p.collateral) seize = p.collateral;
        p.collateral -= seize;
        IERC20(token).transfer(msg.sender, seize);
    }

    function _currentIndex() internal view returns (uint256) {
        uint256 elapsed = block.number - lastAccrualBlock;
        return borrowIndex + borrowIndex * BORROW_RATE_PER_YEAR * elapsed / BLOCKS_PER_YEAR / 1e18;
    }
}
