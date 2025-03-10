// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

// Rozhraní pro Chainlink oracle (pro získání ceny USD)
interface AggregatorV3Interface {
    function latestRoundData() external view returns (
        uint80 roundId,
        int256 answer,
        uint256 startedAt,
        uint256 updatedAt,
        uint80 answeredInRound
    );
}

// Rozhraní pro ERC-20 tokeny
interface IERC20 {
    function transferFrom(address sender, address recipient, uint256 amount) external returns (bool);
    function transfer(address recipient, uint256 amount) external returns (bool);
    function balanceOf(address account) external view returns (uint256);
    function decimals() external view returns (uint8);
}

// Custom stablecoin contract CUSD
contract CUSD {
    string public name = "Crown USD";
    string public symbol = "CUSD";
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    uint256 public ownerReserveSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    address public owner;
    address public minterManager;
    uint256 public minterEntryFeeUSD = 100_000 * 10**18;
    uint256 public mintingFeePercentage = 5 * 10**15;

    mapping(address => bool) public authorizedMinters;
    mapping(address => bool) public blacklisted;
    mapping(address => bool) public supportedTokens;
    mapping(address => bool) public supportedCollateralTokens;
    mapping(address => uint256) public reserves;
    mapping(address => mapping(address => uint256)) public collateral;

    mapping(address => address) public priceFeeds;
    address public constant ETH_USD_ORACLE = 0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419;
    address public constant USDC_USD_ORACLE = 0x8fFfFfd4AfB6115b954Bd326cbe7B4BA576818f6;
    address public constant USDT_USD_ORACLE = 0x3E7d1eAB13ad0104d2750B8863b489D65364e32D;
    address public constant DAI_USD_ORACLE = 0xAed0c38402a5d19df6E4c03F4E2DceD6e29c1ee9;

    address[] public collateralTokensList;
    uint256 public cachedCollateralValue;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);
    event BlacklistAdded(address indexed _address);
    event BlacklistRemoved(address indexed _address);
    event MinterAuthorized(address indexed minter);
    event FeesUpdated(uint256 newEntryFeeUSD, uint256 newMintingFeePercentage);
    event TokensWithdrawn(address indexed token, uint256 amount);
    event CollateralAdded(address indexed minter, address indexed token, uint256 amount);
    event CollateralWithdrawn(address indexed minter, address indexed token, uint256 amount);
    event OwnerReserveMint(address indexed owner, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event SupportedTokenUpdated(address indexed token, bool isSupported);
    event SupportedCollateralTokenUpdated(address indexed token, bool isSupported);
    event PriceFeedUpdated(address indexed token, address indexed priceFeed);
    event CollateralValueUpdated(uint256 newValue);

    modifier onlyOwner() {
        require(msg.sender == owner, "Caller is not the owner");
        _;
    }

    modifier notBlacklisted(address _address) {
        require(!blacklisted[_address], "Address is blacklisted");
        _;
    }

    constructor() {
        owner = msg.sender;
        minterManager = address(0);
        totalSupply = 0;
        ownerReserveSupply = 0;
        cachedCollateralValue = 0;

        priceFeeds[address(0)] = ETH_USD_ORACLE;
        priceFeeds[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = USDC_USD_ORACLE;
        priceFeeds[0xdAC17F958D2ee523a2206206994597C13D831ec7] = USDT_USD_ORACLE;
        priceFeeds[0x6B175474E89094C44Da98b954EedeAC495271d0F] = DAI_USD_ORACLE;

        supportedTokens[address(0)] = true;
        supportedTokens[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = true;
        supportedTokens[0xdAC17F958D2ee523a2206206994597C13D831ec7] = true;
        supportedTokens[0x6B175474E89094C44Da98b954EedeAC495271d0F] = true;

        supportedCollateralTokens[address(0)] = true;
        supportedCollateralTokens[0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48] = true;
        supportedCollateralTokens[0xdAC17F958D2ee523a2206206994597C13D831ec7] = true;
        supportedCollateralTokens[0x6B175474E89094C44Da98b954EedeAC495271d0F] = true;

        collateralTokensList.push(address(0));
        collateralTokensList.push(0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48);
        collateralTokensList.push(0xdAC17F958D2ee523a2206206994597C13D831ec7);
        collateralTokensList.push(0x6B175474E89094C44Da98b954EedeAC495271d0F);
    }

    function transferOwnership(address newOwner) external onlyOwner {
        require(newOwner != address(0), "Invalid new owner address");
        address oldOwner = owner;
        owner = newOwner;
        emit OwnershipTransferred(oldOwner, newOwner);
    }

    function transfer(address to, uint256 value) external notBlacklisted(msg.sender) notBlacklisted(to) returns (bool) {
        require(to != address(0), "Invalid address");
        require(balanceOf[msg.sender] >= value, "Insufficient balance");
        require(cachedCollateralValue >= totalSupply, "Insufficient collateral for stability");

        balanceOf[msg.sender] -= value;
        balanceOf[to] += value;
        emit Transfer(msg.sender, to, value);
        return true;
    }

    function approve(address spender, uint256 value) external notBlacklisted(msg.sender) returns (bool) {
        require(spender != address(0), "Invalid address");
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external notBlacklisted(from) notBlacklisted(to) returns (bool) {
        require(to != address(0), "Invalid address");
        require(balanceOf[from] >= value, "Insufficient balance");
        require(allowance[from][msg.sender] >= value, "Insufficient allowance");
        require(cachedCollateralValue >= totalSupply, "Insufficient collateral for stability");

        balanceOf[from] -= value;
        balanceOf[to] += value;
        allowance[from][msg.sender] -= value;
        emit Transfer(from, to, value);
        return true;
    }

    function authorizeMinter(address minter, address paymentToken, uint256 paymentAmount) external payable notBlacklisted(msg.sender) notBlacklisted(minter) {
        require(minter != address(0), "Invalid minter address");
        require(supportedTokens[paymentToken], "Unsupported payment token");
        require(paymentAmount > 0, "Payment amount must be greater than 0");

        uint256 tokenPriceUSD = getTokenPriceUSD(paymentToken);
        uint8 tokenDecimals = (paymentToken == address(0)) ? 18 : IERC20(paymentToken).decimals();
        uint256 adjustedAmount = paymentAmount * (10 ** (18 - tokenDecimals));
        require((adjustedAmount * tokenPriceUSD) / 10**18 >= minterEntryFeeUSD, "Insufficient payment for entry fee");

        if (paymentToken == address(0)) {
            require(msg.value >= paymentAmount, "Insufficient ETH payment");
            (bool success, ) = owner.call{value: paymentAmount}("");
            require(success, "ETH transfer to owner failed");
        } else {
            IERC20(paymentToken).transferFrom(msg.sender, owner, paymentAmount);
        }
        authorizedMinters[minter] = true;
        emit MinterAuthorized(minter);
    }

    function ownerMint(uint256 amount) external onlyOwner {
        require(amount > 0, "Amount must be greater than 0");

        ownerReserveSupply += amount;
        balanceOf[owner] += amount;
        emit OwnerReserveMint(owner, amount);
        emit Transfer(address(0), owner, amount);
    }

    // Pomocná funkce pro výpočet hodnoty kolaterálu
    function calculateCollateralValueUSD(address token, uint256 amount) internal view returns (uint256) {
        uint8 tokenDecimals = (token == address(0)) ? 18 : IERC20(token).decimals();
        uint256 adjustedAmount = amount * (10 ** (18 - tokenDecimals));
        return (adjustedAmount * getTokenPriceUSD(token)) / 10**18;
    }

    // Pomocná funkce pro výpočet poplatku
    function calculateFeeAmount(uint256 amount, address feeToken) internal view returns (uint256) {
        uint256 requiredFee = (amount * mintingFeePercentage) / 10**18;
        uint8 feeDecimals = (feeToken == address(0)) ? 18 : IERC20(feeToken).decimals();
        uint256 feeTokenPriceUSD = getTokenPriceUSD(feeToken);
        return (requiredFee * (10 ** feeDecimals)) / feeTokenPriceUSD;
    }

    function mint(address to, uint256 amount, address collateralToken, uint256 collateralAmount, address feeToken, uint256 feeAmount) external payable notBlacklisted(msg.sender) notBlacklisted(to) {
        require(authorizedMinters[msg.sender], "Caller is not an authorized minter");
        require(to != address(0), "Invalid address");
        require(amount > 0, "Amount must be greater than 0");
        require(supportedCollateralTokens[collateralToken], "Unsupported collateral token");
        require(supportedTokens[feeToken], "Unsupported fee token");

        // Kolaterál
        uint256 collateralValueUSD = calculateCollateralValueUSD(collateralToken, collateralAmount);
        require(collateralValueUSD >= amount, "Insufficient collateral value");

        if (collateralToken == address(0)) {
            require(msg.value >= collateralAmount, "Insufficient ETH collateral");
            collateral[msg.sender][address(0)] += collateralAmount;
        } else {
            IERC20(collateralToken).transferFrom(msg.sender, address(this), collateralAmount);
            collateral[msg.sender][collateralToken] += collateralAmount;
        }

        // Aktualizace cached hodnoty
        cachedCollateralValue += collateralValueUSD;
        require(cachedCollateralValue >= totalSupply + amount, "Insufficient collateral for stability");

        // Poplatek
        uint256 adjustedFeeAmount = calculateFeeAmount(amount, feeToken);
        require(feeAmount >= adjustedFeeAmount, "Insufficient fee amount");

        if (feeToken == address(0)) {
            require(msg.value >= collateralAmount + feeAmount, "Insufficient ETH for fee");
            (bool success, ) = owner.call{value: feeAmount}("");
            require(success, "ETH fee transfer to owner failed");
        } else {
            IERC20(feeToken).transferFrom(msg.sender, owner, feeAmount);
        }

        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
        emit CollateralAdded(msg.sender, collateralToken, collateralAmount);
        emit CollateralValueUpdated(cachedCollateralValue);
    }

    function withdrawCollateral(address token, uint256 amount) external notBlacklisted(msg.sender) {
        require(supportedCollateralTokens[token], "Unsupported collateral token");
        require(collateral[msg.sender][token] >= amount, "Insufficient collateral");

        uint256 collateralValueUSD = calculateCollateralValueUSD(token, amount);
        require(cachedCollateralValue >= totalSupply + collateralValueUSD, "Insufficient collateral for stability after withdrawal");

        collateral[msg.sender][token] -= amount;
        cachedCollateralValue -= collateralValueUSD;

        if (token == address(0)) {
            (bool success, ) = msg.sender.call{value: amount}("");
            require(success, "Collateral withdrawal failed");
        } else {
            IERC20(token).transfer(msg.sender, amount);
        }
        emit CollateralWithdrawn(msg.sender, token, amount);
        emit CollateralValueUpdated(cachedCollateralValue);
    }

    function addToBlacklist(address _address) external onlyOwner {
        require(_address != address(0), "Invalid address");
        require(!blacklisted[_address], "Address is already blacklisted");
        blacklisted[_address] = true;
        emit BlacklistAdded(_address);
    }

    function removeFromBlacklist(address _address) external onlyOwner {
        require(_address != address(0), "Invalid address");
        require(blacklisted[_address], "Address is not blacklisted");
        blacklisted[_address] = false;
        emit BlacklistRemoved(_address);
    }

    function updateSupportedToken(address token, bool isSupported) external onlyOwner {
        require(token != address(0) || token == address(0), "Invalid token address");
        supportedTokens[token] = isSupported;
        emit SupportedTokenUpdated(token, isSupported);
    }

    function updateSupportedCollateralToken(address token, bool isSupported) external onlyOwner {
        require(token != address(0) || token == address(0), "Invalid token address");
        if (isSupported && !supportedCollateralTokens[token]) {
            require(priceFeeds[token] != address(0), "Price feed must be set before adding token");
            supportedCollateralTokens[token] = true;
            collateralTokensList.push(token);
        } else if (!isSupported && supportedCollateralTokens[token]) {
            supportedCollateralTokens[token] = false;
            for (uint i = 0; i < collateralTokensList.length; i++) {
                if (collateralTokensList[i] == token) {
                    collateralTokensList[i] = collateralTokensList[collateralTokensList.length - 1];
                    collateralTokensList.pop();
                    break;
                }
            }
            recalculateCollateralValue();
        }
        emit SupportedCollateralTokenUpdated(token, isSupported);
    }

    function updatePriceFeed(address token, address priceFeed) external onlyOwner {
        require(token != address(0) || token == address(0), "Invalid token address");
        require(priceFeed != address(0), "Invalid price feed address");
        priceFeeds[token] = priceFeed;
        if (supportedCollateralTokens[token]) {
            recalculateCollateralValue();
        }
        emit PriceFeedUpdated(token, priceFeed);
    }

    function updateFees(uint256 newEntryFeeUSD, uint256 newMintingFeePercentage) external onlyOwner {
        minterEntryFeeUSD = newEntryFeeUSD;
        mintingFeePercentage = newMintingFeePercentage;
        emit FeesUpdated(newEntryFeeUSD, newMintingFeePercentage);
    }

    function withdrawTokens(address token, uint256 amount) external onlyOwner {
        if (token == address(0)) {
            require(address(this).balance >= amount, "Insufficient ETH balance");
            (bool success, ) = owner.call{value: amount}("");
            require(success, "ETH withdrawal failed");
            cachedCollateralValue -= calculateCollateralValueUSD(token, amount);
        } else {
            require(reserves[token] >= amount, "Insufficient reserves");
            reserves[token] -= amount;
            IERC20(token).transfer(owner, amount);
        }
        emit TokensWithdrawn(token, amount);
        emit CollateralValueUpdated(cachedCollateralValue);
    }

    function getCUSDValue() public view returns (uint256) {
        return cachedCollateralValue;
    }

    function recalculateCollateralValue() public onlyOwner {
        uint256 totalCollateralUSD = 0;

        for (uint i = 0; i < collateralTokensList.length; i++) {
            address token = collateralTokensList[i];
            if (supportedCollateralTokens[token] && priceFeeds[token] != address(0)) {
                (, int256 price, , , ) = AggregatorV3Interface(priceFeeds[token]).latestRoundData();
                if (price > 0) {
                    uint256 balance = (token == address(0)) ? address(this).balance : IERC20(token).balanceOf(address(this));
                    uint8 tokenDecimals = (token == address(0)) ? 18 : IERC20(token).decimals();
                    totalCollateralUSD += (balance * uint256(price)) / (10 ** tokenDecimals);
                }
            }
        }

        cachedCollateralValue = totalCollateralUSD;
        emit CollateralValueUpdated(cachedCollateralValue);
    }

    function getTokenPriceUSD(address token) internal view returns (uint256) {
        address oracleAddress = priceFeeds[token];
        require(oracleAddress != address(0), "No price feed for token");
        (, int256 price, , , ) = AggregatorV3Interface(oracleAddress).latestRoundData();
        require(price > 0, "Invalid price feed");
        return uint256(price);
    }

    function getCollateralTokensCount() external view returns (uint256) {
        return collateralTokensList.length;
    }

    receive() external payable {}
}
