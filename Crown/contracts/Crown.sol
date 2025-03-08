// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

contract Crown is ReentrancyGuard {
    string public name = "Crown"; 
    string public symbol = "CRW"; 
    uint8 public constant decimals = 18;
    uint256 public totalSupply = 21000000000 * (10 ** uint256(decimals)); 

    address public owner; 
    uint256 public reserveTokens; 
    uint256 public reserveETH; 
    uint256 public collateralReserveETH;
    uint256 public tokenPriceBase;
    uint256 public totalSoldTokens; 
    bool public useOraclePrice = false; 
    uint256 public oraclePrice; 
    AggregatorV3Interface internal priceFeed; 

    uint256 public constant reserveAllocation = 12000000000 * (10 ** decimals); 
    uint256 public constant ownerAllocation = 6000000000 * (10 ** decimals); 
    uint256 public constant rewardPoolInitialAllocation = 3000000000 * (10 ** decimals); 
    uint256 public rewardPool; 

    uint256 public DAILY_REWARD_RATE = 2; // 0.02%
    uint256 public transactionFeeRate = 10; // 1%
    uint256 public dailyInterestRate = 2; // 0.02%
    uint256 public maxLoanDuration = 365 days;

    struct StakerInfo {
        uint256 stakedAmount; 
        uint256 lastClaimedTime; 
        uint256 totalClaimedRewards;
    }

    struct Validator {
        address validatorAddress; 
        uint256 stake; 
        uint256 rewards; 
    }

    struct Loan {
        uint256 collateralWei; 
        uint256 loanAmount; 
        uint256 duration; 
        uint256 startTime; 
        bool isActive; 
    }

    struct UserLoan {
        address lender; 
        address borrower; 
        uint256 collateralTokens; 
        uint256 loanAmount; 
        uint256 interestRate; 
        uint256 startTime;  
        uint256 loanDuration; 
        bool isActive;
    }

    mapping(address => uint256) public balanceOf; 
    mapping(address => mapping(address => uint256)) public allowance; 
    mapping(address => StakerInfo) public stakerInfo; 
    mapping(address => Loan) public loans; 
    mapping(address => UserLoan) public userLoans; 
    mapping(address => address) public borrowerToLender; 
    Validator[] public validators; 

    event TransactionFeeRateUpdated(uint256 oldRate, uint256 newRate);
    event UseOraclePriceUpdated(address indexed owner, bool newStatus);
    event TokensBought(address indexed buyer, uint256 ethAmountInWei, uint256 tokensBought, uint256 feeInTokens, uint256 ownerFee, uint256 rewardPoolFee, uint256 validatorsFee, uint256 contractEthBalance);
    event TokensSold(address indexed seller, uint256 tokenAmount, uint256 ethReceived, uint256 feeInTokens, uint256 ownerFee, uint256 rewardPoolFee, uint256 validatorsFee, uint256 contractEthBalance);
    event Transfer(address indexed from, address indexed to, uint256 value);
    event OwnerFeeTransferred(address indexed from, address indexed owner, uint256 feeAmount);
    event RewardPoolFeeTransferred(address indexed from, uint256 feeAmount);
    event ValidatorFeesDistributed(uint256 totalValidatorFee, uint256 individualValidatorShare);
    event TokenPriceUpdated(uint256 newPrice);
    event Approval(address indexed owner, address indexed spender, uint256 amount);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event Staked(address indexed staker, uint256 amountStaked);
    event RewardsClaimed(address indexed staker, uint256 rewardsClaimed);
    event Unstaked(address indexed staker, uint256 amountUnstaked);
    event DailyRewardRateUpdated(uint256 oldRate, uint256 newRate);
    event ValidatorAdded(address indexed validatorAddress, uint256 stakedAmount);
    event ValidatorRemoved(address indexed validatorAddress);
    event RewardsWithdrawn(address indexed validator, uint256 amount);
    event LoanCreated(address indexed borrower, uint256 collateralWei, uint256 loanAmount);
    event LoanRepaid(address indexed borrower, uint256 collateralReturned, uint256 totalRepayment);
    event CollateralLiquidated(address indexed borrower, uint256 collateralWei, uint256 reserveShareInWei);
    event EthTransferAttempted(address indexed to, uint256 amount, bool success);
    event DailyInterestRateUpdated(uint256 newRate);
    event UserLoanCreated(address indexed lender, address indexed borrower, uint256 loanAmount, uint256 interestRate, uint256 loanDuration);
    event UserLoanActivated(address indexed borrower, uint256 collateralAmount, uint256 loanAmount);
    event UserLoanRepaid(address indexed borrower, address indexed lender, uint256 totalRepaymentAmount, uint256 remainingCollateral);
    event UserLoanLiquidated(address indexed borrower, address indexed lender, uint256 totalCollateral, uint256 lenderShare, uint256 ownerShare, uint256 rewardPoolShare, uint256 liquidationTimestamp);
    event UserLoanCancelled(address indexed lender);

    constructor(address _priceFeed) { 
        owner = msg.sender; 
        priceFeed = AggregatorV3Interface(_priceFeed); 
        reserveTokens = reserveAllocation; 
        rewardPool = rewardPoolInitialAllocation; 
        tokenPriceBase = 0.00001 ether; 
        balanceOf[owner] = ownerAllocation; 
        emit Transfer(address(0), owner, ownerAllocation); 
    }

    modifier onlyOwner() {
        require(msg.sender == owner, "Not the contract owner");
        _;
    }

    modifier onlyValidator() {
        bool isValidator = false; 
        for (uint256 i = 0; i < validators.length; i++) { 
            if (validators[i].validatorAddress == msg.sender) { 
                isValidator = true; 
                break; 
            }
        }
        require(isValidator, "You are not a validator"); 
        _;
    }

    modifier hasNoActiveLoan() {
        require(!loans[msg.sender].isActive, "You already have an active loan"); 
        _;
    }

    function _getCurrentTokenPrice() internal view returns (uint256) {
        if (useOraclePrice) {
            (, int256 price,,,) = priceFeed.latestRoundData();
            return uint256(price);
        } else {
            return tokenPriceBase;
        }
    }

    function _updateTokenPrice(uint256 tokenAmount, bool isBuy) internal {
        uint256 adjustment = (tokenAmount / (10 ** uint256(decimals))) * 0.000000013 ether;
        if (isBuy) {
            tokenPriceBase += adjustment;
        } else if (tokenPriceBase > adjustment) {
            tokenPriceBase -= adjustment;
        } else {
            tokenPriceBase = 0;
        }
        emit TokenPriceUpdated(tokenPriceBase);
    }

    function setTransactionFeeRate(uint256 newRate) external onlyOwner {
        require(newRate > 0 && newRate <= 100, "Invalid fee rate"); 
        uint256 oldRate = transactionFeeRate; 
        transactionFeeRate = newRate; 
        emit TransactionFeeRateUpdated(oldRate, newRate); 
    }

    function buyTokensWithETH(uint256 ethAmountInWei) external payable nonReentrant {
        require(ethAmountInWei > 0, "You must specify an amount greater than 0 wei");
        require(msg.value == ethAmountInWei, "Sent ETH must match the specified amount");

        uint256 currentTokenPrice = _getCurrentTokenPrice();
        uint256 tokensToBuy = (ethAmountInWei * (10 ** uint256(decimals))) / currentTokenPrice;
        require(tokensToBuy <= reserveTokens, "Not enough tokens in reserve");

        uint256 feeInBaseUnits = (tokensToBuy * transactionFeeRate) / 10000;
        uint256 tokensAfterFee = tokensToBuy - feeInBaseUnits;

        uint256 ownerFee = (feeInBaseUnits * 15) / 100;
        uint256 rewardPoolFee = (feeInBaseUnits * 50) / 100;
        uint256 validatorsFee = (feeInBaseUnits * 35) / 100;

        balanceOf[owner] += ownerFee;
        rewardPool += rewardPoolFee;

        if (validators.length > 0) {
            uint256 validatorShare = validatorsFee / validators.length;
            for (uint256 i = 0; i < validators.length; i++) {
                validators[i].rewards += validatorShare;
            }
        }

        reserveETH += ethAmountInWei;
        reserveTokens -= tokensToBuy;
        balanceOf[msg.sender] += tokensAfterFee;
        totalSoldTokens += tokensAfterFee; 

        emit TokensBought(msg.sender, ethAmountInWei, tokensAfterFee, feeInBaseUnits, ownerFee, rewardPoolFee, validatorsFee, address(this).balance);

        if (!useOraclePrice) {
            _updateTokenPrice(tokensToBuy, true); 
        }
    }

    function sellTokensForETH(uint256 tokenAmount) external nonReentrant {
        require(tokenAmount > 0, "You must sell more than 0 tokens");

        uint256 tokenAmountInBaseUnits = tokenAmount * (10 ** uint256(decimals));
        require(balanceOf[msg.sender] >= tokenAmountInBaseUnits, "Insufficient token balance");

        uint256 currentTokenPrice = _getCurrentTokenPrice();
        uint256 ethAmount = (tokenAmountInBaseUnits * currentTokenPrice) / (10 ** uint256(decimals));
        require(ethAmount <= reserveETH, "Not enough ETH in reserve");
        require(address(this).balance >= ethAmount, "Contract lacks sufficient ETH");

        uint256 feeInBaseUnits = (tokenAmountInBaseUnits * transactionFeeRate) / 10000;
        uint256 tokensAfterFee = tokenAmountInBaseUnits - feeInBaseUnits;

        uint256 ownerFee = (feeInBaseUnits * 15) / 100;
        uint256 rewardPoolFee = (feeInBaseUnits * 50) / 100;
        uint256 validatorsFee = (feeInBaseUnits * 35) / 100;

        balanceOf[owner] += ownerFee;
        rewardPool += rewardPoolFee;

        if (validators.length > 0) {
            uint256 validatorShare = validatorsFee / validators.length;
            for (uint256 i = 0; i < validators.length; i++) {
                validators[i].rewards += validatorShare;
            }
        }

        reserveETH -= ethAmount;
        reserveTokens += tokensAfterFee; // Oprava: pouze tokensAfterFee
        balanceOf[msg.sender] -= tokenAmountInBaseUnits;
        totalSoldTokens -= tokensAfterFee;

        (bool sent, ) = payable(msg.sender).call{value: ethAmount}("");
        require(sent, "Failed to send ETH");

        emit Transfer(msg.sender, address(this), tokenAmountInBaseUnits);
        emit TokensSold(msg.sender, tokenAmountInBaseUnits, ethAmount, feeInBaseUnits, ownerFee, rewardPoolFee, validatorsFee, address(this).balance);

        if (!useOraclePrice) { 
            _updateTokenPrice(tokensAfterFee, false); 
        }
    }

    function getContractBalance() external view returns (uint256) {
        return address(this).balance;
    }

    function transfer(address to, uint256 amountInBaseUnits) external nonReentrant returns (bool) { 
        require(to != address(0), "Cannot transfer to the zero address"); 
        require(balanceOf[msg.sender] >= amountInBaseUnits, "Insufficient balance"); 

        uint256 currentPrice = _getCurrentTokenPrice(); 
        emit TokenPriceUpdated(currentPrice); 

        uint256 fee = (amountInBaseUnits * 1) / 100; // 1% poplatek
        uint256 amountAfterFee = amountInBaseUnits - fee; 

        uint256 ownerFee = (fee * 15) / 100; // Oprava: z fee, ne z celku
        uint256 rewardPoolFee = (fee * 50) / 100; 
        uint256 validatorsFee = (fee * 35) / 100; 

        balanceOf[msg.sender] -= amountInBaseUnits; 
        balanceOf[to] += amountAfterFee; 
        balanceOf[owner] += ownerFee; 
        rewardPool += rewardPoolFee; 

        if (validators.length > 0) {
            uint256 validatorShare = validatorsFee / validators.length; 
            for (uint256 i = 0; i < validators.length; i++) {
                validators[i].rewards += validatorShare; 
                emit ValidatorFeesDistributed(validatorsFee, validatorShare); 
            }
        }

        emit Transfer(msg.sender, to, amountAfterFee); 
        emit OwnerFeeTransferred(msg.sender, owner, ownerFee); 
        emit RewardPoolFeeTransferred(msg.sender, rewardPoolFee); 
        return true; 
    }

    function approve(address spender, uint256 amountInBaseUnits) external returns (bool) { 
        require(spender != address(0), "Cannot approve the zero address");
        allowance[msg.sender][spender] = amountInBaseUnits; 
        emit Approval(msg.sender, spender, amountInBaseUnits); 
        return true; 
    }

    function transferFrom(address from, address to, uint256 amountInBaseUnits) external nonReentrant returns (bool) { 
        require(from != address(0), "Cannot transfer from the zero address"); 
        require(to != address(0), "Cannot transfer to the zero address");
        require(balanceOf[from] >= amountInBaseUnits, "Insufficient balance");
        require(allowance[from][msg.sender] >= amountInBaseUnits, "Allowance exceeded"); 

        uint256 currentPrice = _getCurrentTokenPrice(); 
        emit TokenPriceUpdated(currentPrice); 

        uint256 feeInBaseUnits = (amountInBaseUnits * transactionFeeRate) / 10000; 
        uint256 amountAfterFee = amountInBaseUnits - feeInBaseUnits; 

        balanceOf[from] -= amountInBaseUnits; 
        balanceOf[to] += amountAfterFee; 
        allowance[from][msg.sender] -= amountInBaseUnits; 

        uint256 ownerFee = (feeInBaseUnits * 15) / 100; 
        uint256 rewardPoolFee = (feeInBaseUnits * 50) / 100; 
        uint256 validatorsFee = (feeInBaseUnits * 35) / 100; 

        balanceOf[owner] += ownerFee; 
        rewardPool += rewardPoolFee; 

        if (validators.length > 0) { 
            uint256 validatorShare = validatorsFee / validators.length; 
            for (uint256 i = 0; i < validators.length; i++) {
                validators[i].rewards += validatorShare; 
            }
        }

        emit Transfer(from, to, amountAfterFee); 
        emit Transfer(from, owner, ownerFee); 
        return true; 
    }

    function transferOwnership(address newOwner) external onlyOwner nonReentrant { 
        require(newOwner != address(0), "New owner cannot be zero address"); 
        emit OwnershipTransferred(owner, newOwner); 
        owner = newOwner; 
    }

    function stake(uint256 amountInBaseUnits) external nonReentrant {
        require(amountInBaseUnits > 0, "Amount must be greater than zero");
        require(balanceOf[msg.sender] >= amountInBaseUnits, "Insufficient balance");

        StakerInfo storage info = stakerInfo[msg.sender];
        uint256 fee = (amountInBaseUnits * transactionFeeRate) / 10000;
        uint256 amountAfterFee = amountInBaseUnits - fee;

        uint256 ownerFee = fee / 2;
        uint256 rewardPoolFee = fee - ownerFee;

        balanceOf[owner] += ownerFee;
        rewardPool += rewardPoolFee;
        info.stakedAmount += amountAfterFee;
        info.lastClaimedTime = block.timestamp;
        balanceOf[msg.sender] -= amountInBaseUnits;

        emit Staked(msg.sender, amountAfterFee);
    }

    function claimRewardStake() public nonReentrant {
        StakerInfo storage info = stakerInfo[msg.sender];
        uint256 rewards = getPendingRewards(msg.sender);
        require(rewards > 0, "Not enough rewards");
        require(rewardPool >= rewards, "Insufficient reward pool");

        uint256 fee = (rewards * transactionFeeRate) / 10000;
        uint256 rewardsAfterFee = rewards - fee;

        uint256 poolFee = (fee * 70) / 100;
        uint256 ownerFee = fee - poolFee;

        balanceOf[owner] += ownerFee;
        rewardPool += poolFee;
        rewardPool -= rewards;
        balanceOf[msg.sender] += rewardsAfterFee;

        info.totalClaimedRewards += rewardsAfterFee;
        info.lastClaimedTime = block.timestamp;

        emit RewardsClaimed(msg.sender, rewardsAfterFee);
    }

    function unstake() external nonReentrant {
        StakerInfo storage info = stakerInfo[msg.sender];
        require(info.stakedAmount > 0, "No staked tokens to unstake");

        uint256 rewards = getPendingRewards(msg.sender);
        if (rewards > 0) {
            require(rewardPool >= rewards, "Insufficient reward pool");
            uint256 fee = (rewards * transactionFeeRate) / 10000;
            uint256 rewardsAfterFee = rewards - fee;

            uint256 poolFee = (fee * 70) / 100;
            uint256 ownerFee = fee - poolFee;

            balanceOf[owner] += ownerFee;
            rewardPool += poolFee;
            rewardPool -= rewards;
            balanceOf[msg.sender] += rewardsAfterFee;
            info.totalClaimedRewards += rewardsAfterFee;
            emit RewardsClaimed(msg.sender, rewardsAfterFee);
        }

        uint256 amountToUnstake = info.stakedAmount;
        balanceOf[msg.sender] += amountToUnstake;
        info.stakedAmount = 0;
        info.lastClaimedTime = 0;

        emit Unstaked(msg.sender, amountToUnstake);
    }

    function getPendingRewards(address staker) public view returns (uint256) {
        StakerInfo storage info = stakerInfo[staker];
        if (info.stakedAmount == 0) return 0;

        uint256 timeElapsed = block.timestamp - info.lastClaimedTime;
        uint256 pendingRewards = (info.stakedAmount * DAILY_REWARD_RATE * timeElapsed) / (10000 * 1 days);
        return pendingRewards;
    }

    function updateDailyRewardRate(uint256 newRate) external onlyOwner {
        require(newRate > 0 && newRate <= 100, "Reward rate must be between 0 and 1%"); 
        uint256 oldRate = DAILY_REWARD_RATE; 
        DAILY_REWARD_RATE = newRate; 
        emit DailyRewardRateUpdated(oldRate, newRate);
    }

    function addValidator() external nonReentrant { 
        for (uint256 i = 0; i < validators.length; i++) { 
            require(validators[i].validatorAddress != msg.sender, "Already a validator"); 
        }
    
        require(balanceOf[msg.sender] >= 1000 * (10 ** uint256(decimals)), "Must stake 1000 tokens to become a validator"); 
        balanceOf[msg.sender] -= 1000 * (10 ** uint256(decimals));

        validators.push(Validator({
            validatorAddress: msg.sender, 
            stake: 1000 * (10 ** uint256(decimals)), 
            rewards: 0 
        }));

        emit ValidatorAdded(msg.sender, 1000 * (10 ** uint256(decimals))); 
    }

    function removeValidator() external nonReentrant { 
        for (uint256 i = 0; i < validators.length; i++) { 
            uint256 currentPrice = _getCurrentTokenPrice(); 
            emit TokenPriceUpdated(currentPrice); 

            if (validators[i].validatorAddress == msg.sender) {
                uint256 rewardsToDistribute = validators[i].rewards; 
                balanceOf[msg.sender] += validators[i].stake;

                uint256 rewardPoolShare = rewardsToDistribute * 20 / 100; 
                uint256 ownerShare = rewardsToDistribute * 5 / 100; 
                uint256 validatorsShare = rewardsToDistribute * 75 / 100; 
        
                rewardPool += rewardPoolShare; 
                balanceOf[owner] += ownerShare; 
        
                uint256 remainingValidators = validators.length - 1; 
                if (remainingValidators > 0) {
                    uint256 sharePerValidator = validatorsShare / remainingValidators; 
                    for (uint256 j = 0; j < validators.length; j++) {
                        if (validators[j].validatorAddress != msg.sender) { 
                            validators[j].rewards += sharePerValidator; 
                        }
                    }
                }

                validators[i] = validators[validators.length - 1]; 
                validators.pop(); 
                emit ValidatorRemoved(msg.sender); 
                return; 
            }
        }
        revert("Not a validator");
    }

    function withdrawRewards() external nonReentrant {
        uint256 totalRewards = 0; 
        uint256 currentPrice = _getCurrentTokenPrice(); 
        emit TokenPriceUpdated(currentPrice); 

        for (uint256 i = 0; i < validators.length; i++) { 
            if (validators[i].validatorAddress == msg.sender) { 
                totalRewards = validators[i].rewards; 
                validators[i].rewards = 0; 
                break; 
            }
        }

        require(totalRewards > 0, "No rewards to withdraw"); 
        balanceOf[msg.sender] += totalRewards; 
        emit RewardsWithdrawn(msg.sender, totalRewards); 
    }

    function getValidators() external view returns (address[] memory, uint256[] memory, uint256[] memory) {
        address[] memory addresses = new address[](validators.length); 
        uint256[] memory stakes = new uint256[](validators.length); 
        uint256[] memory rewards = new uint256[](validators.length); 

        for (uint256 i = 0; i < validators.length; i++) { 
            addresses[i] = validators[i].validatorAddress; 
            stakes[i] = validators[i].stake; 
            rewards[i] = validators[i].rewards; 
        }
        return (addresses, stakes, rewards); 
    }

    function createLoan(uint256 collateralWei, uint256 duration) external payable nonReentrant hasNoActiveLoan {
        require(collateralWei > 0, "Collateral must be greater than zero");
        require(msg.value == collateralWei, "Sent ETH must match collateral");
        require(duration > 0, "Loan duration must be greater than zero");
        require(duration <= maxLoanDuration, "Loan duration cannot exceed 365 days");

        uint256 currentPrice = _getCurrentTokenPrice();
        emit TokenPriceUpdated(currentPrice);

        uint256 maxLoanAmount = collateralWei * (10 ** decimals) / currentPrice;
        require(reserveTokens >= maxLoanAmount, "Not enough tokens in reserve");

        _updateTokenPriceForLoan(maxLoanAmount, true);
        reserveTokens -= maxLoanAmount;
        balanceOf[msg.sender] += maxLoanAmount;
        totalSoldTokens += maxLoanAmount;

        loans[msg.sender] = Loan({
            collateralWei: collateralWei,
            loanAmount: maxLoanAmount,
            startTime: block.timestamp,
            duration: duration,
            isActive: true
        });

        collateralReserveETH += collateralWei; 
        emit LoanCreated(msg.sender, collateralWei, maxLoanAmount);
        emit Transfer(address(0), msg.sender, maxLoanAmount);
    }

    function repayLoan() external nonReentrant {
        Loan storage loan = loans[msg.sender];
        require(loan.isActive, "No active loan to repay");

        uint256 loanDuration = block.timestamp - loan.startTime;
        require(loanDuration <= loan.duration, "Loan duration has expired, repay not allowed");

        uint256 currentPrice = _getCurrentTokenPrice();
        emit TokenPriceUpdated(currentPrice);

        uint256 interest = (loan.loanAmount * dailyInterestRate * loanDuration) / (10000 * 1 days);
        uint256 totalRepayment = loan.loanAmount + interest;

        require(balanceOf[msg.sender] >= totalRepayment, "Insufficient tokens to repay loan and interest");

        balanceOf[msg.sender] -= totalRepayment;
        reserveTokens += loan.loanAmount;
        totalSoldTokens -= loan.loanAmount;

        _updateTokenPriceForLoan(loan.loanAmount, false);

        uint256 interestInWei = (interest * currentPrice) / 10**18; 
        uint256 ownerShareInWei = interestInWei / 2;
        uint256 reserveShareInWei = interestInWei - ownerShareInWei;

        reserveETH += reserveShareInWei;
        balanceOf[owner] += ownerShareInWei / currentPrice;

        loan.isActive = false;
        uint256 collateralReturn = loan.collateralWei;
        collateralReserveETH -= collateralReturn;
        delete loans[msg.sender];

        (bool sent, ) = payable(msg.sender).call{value: collateralReturn}("");
        require(sent, "Failed to return collateral");

        emit LoanRepaid(msg.sender, collateralReturn, totalRepayment);
        emit Transfer(msg.sender, address(0), totalRepayment);
    }

    function _updateTokenPriceForLoan(uint256 tokenAmount, bool isLoanCreation) internal {
        uint256 adjustment = (tokenAmount / (10 ** uint256(decimals))) * 0.000000013 ether; 
        if (isLoanCreation) {
            tokenPriceBase += adjustment; 
        } else {
            if (tokenPriceBase > adjustment) {
                tokenPriceBase -= adjustment; 
            } else {
                tokenPriceBase = 0; 
            }
        }
        emit TokenPriceUpdated(tokenPriceBase); 
    }

    function liquidateCollateral(address borrower) external nonReentrant onlyOwner {
        Loan storage loan = loans[borrower];
        require(loan.isActive, "No active loan to liquidate");

        uint256 loanDuration = block.timestamp - loan.startTime;
        require(loanDuration > loan.duration, "Loan duration has not expired");

        uint256 currentPrice = _getCurrentTokenPrice();
        emit TokenPriceUpdated(currentPrice);

        uint256 collateralWeiToDistribute = loan.collateralWei;
        uint256 reserveShareInWei = (collateralWeiToDistribute * 90) / 100; 
        uint256 ownerShareInWei = collateralWeiToDistribute - reserveShareInWei; 

        require(address(this).balance >= ownerShareInWei, "Insufficient contract balance to send ETH to owner");

        collateralReserveETH -= collateralWeiToDistribute;
        reserveETH += reserveShareInWei;

        (bool sent, ) = payable(msg.sender).call{value: ownerShareInWei}("");
        require(sent, "Failed to send ETH to owner");

        emit EthTransferAttempted(msg.sender, ownerShareInWei, sent);
        loan.isActive = false;
        delete loans[borrower];

        emit CollateralLiquidated(borrower, collateralWeiToDistribute, reserveShareInWei);
    }

    function updateDailyInterestRate(uint256 newRate) external onlyOwner { 
        require(newRate > 0 && newRate <= 100, "Reward rate must be between 0 and 1%"); 
        dailyInterestRate = newRate; 
        emit DailyInterestRateUpdated(newRate); 
    }

    function createUserLoan(uint256 _loanAmount, uint256 _interestRate, uint256 _loanDuration) external nonReentrant { 
        require(userLoans[msg.sender].isActive == false, "Existing loan must be repaid first"); 

        uint256 currentPrice = _getCurrentTokenPrice(); 
        emit TokenPriceUpdated(currentPrice); 

        uint256 loanAmountInBaseUnits = _loanAmount; 
        balanceOf[msg.sender] -= loanAmountInBaseUnits; 
        balanceOf[address(this)] += loanAmountInBaseUnits; 

        userLoans[msg.sender] = UserLoan({
            lender: msg.sender,
            borrower: address(0),
            collateralTokens: 0,
            loanAmount: loanAmountInBaseUnits, 
            interestRate: _interestRate,
            startTime: block.timestamp,
            loanDuration: _loanDuration,
            isActive: false 
        });

        emit UserLoanCreated(msg.sender, address(0), loanAmountInBaseUnits, _interestRate, _loanDuration);
    }
    
    function activateUserLoan(address lenderAddress, uint256 collateralAmount) external nonReentrant {
        UserLoan storage loan = userLoans[lenderAddress]; 
        require(loan.lender != address(0), "No active loan found for this lender"); 
        require(!loan.isActive, "Loan is already active");

        uint256 collateralAmountInBaseUnits = collateralAmount; 
        uint256 currentPrice = _getCurrentTokenPrice(); 
        emit TokenPriceUpdated(currentPrice); 

        uint256 requiredCollateral = (loan.loanAmount * 130) / 100; 
        require(collateralAmountInBaseUnits >= requiredCollateral, "Insufficient collateral amount");

        require(balanceOf[msg.sender] >= collateralAmountInBaseUnits, "Insufficient token balance for collateral");
        balanceOf[msg.sender] -= collateralAmountInBaseUnits; 
        balanceOf[address(this)] += collateralAmountInBaseUnits; 

        loan.collateralTokens = collateralAmountInBaseUnits; 
        loan.borrower = msg.sender; 
        loan.isActive = true; 

        balanceOf[address(this)] -= loan.loanAmount; 
        balanceOf[msg.sender] += loan.loanAmount; 

        userLoans[msg.sender] = loan; 
        borrowerToLender[msg.sender] = lenderAddress; 

        emit UserLoanActivated(msg.sender, collateralAmount, loan.loanAmount);
    }

    function getLoanByBorrower(address _borrower) external view returns (UserLoan memory) {
        address lender = borrowerToLender[_borrower]; 
        require(lender != address(0), "No loan found for this borrower"); 
        return userLoans[lender]; 
    }
  
    function repayUserLoan() external nonReentrant {
        address lenderAddress = borrowerToLender[msg.sender]; 
        require(lenderAddress != address(0), "No active loan for this borrower"); 

        UserLoan storage loan = userLoans[lenderAddress]; 
        require(loan.isActive, "No active loan to repay"); 

        uint256 loanEndTime = loan.startTime + loan.loanDuration; 
        require(block.timestamp <= loanEndTime, "Loan term has expired, repayment is no longer allowed"); 

        uint256 loanDurationInSeconds = block.timestamp - loan.startTime; 
        uint256 totalInterest = (loan.loanAmount * loan.interestRate * loanDurationInSeconds) / (365 days * 100);

        require(loan.collateralTokens >= totalInterest, "Insufficient collateral to cover interest"); 

        loan.collateralTokens -= totalInterest; 
        balanceOf[lenderAddress] += totalInterest; 
        balanceOf[msg.sender] -= loan.loanAmount; 
        balanceOf[lenderAddress] += loan.loanAmount; 

        uint256 remainingCollateral = loan.collateralTokens; 
        if (remainingCollateral > 0) {
            balanceOf[address(this)] -= remainingCollateral; 
            balanceOf[msg.sender] += remainingCollateral; 
        }

        loan.isActive = false; 
        delete borrowerToLender[msg.sender]; 
        delete userLoans[lenderAddress]; 
        delete userLoans[msg.sender]; 

        emit UserLoanRepaid(msg.sender, lenderAddress, loan.loanAmount + totalInterest, remainingCollateral); 
    }
    
    function liquidateUserLoanByLender(address borrower) external nonReentrant {
        UserLoan storage loan = userLoans[borrower]; 
        require(loan.isActive, "No active loan to liquidate"); 
        require(loan.lender == msg.sender, "Only lender can liquidate this loan"); 

        uint256 loanEndTime = loan.startTime + loan.loanDuration; 
        require(block.timestamp > loanEndTime, "Loan term has not yet expired"); 

        uint256 collateral = loan.collateralTokens; 
        uint256 lenderShare = (collateral * 98) / 100; 
        uint256 ownerShare = (collateral * 1) / 100;  
        uint256 rewardPoolShare = (collateral * 1) / 100; 

        balanceOf[address(this)] -= collateral; 
        balanceOf[loan.lender] += lenderShare; 
        balanceOf[owner] += ownerShare; 
        rewardPool += rewardPoolShare; 

        loan.isActive = false; 
        delete borrowerToLender[borrower]; 
        delete userLoans[loan.lender]; 
        delete userLoans[borrower]; 

        emit UserLoanLiquidated(borrower, loan.lender, collateral, lenderShare, ownerShare, rewardPoolShare, block.timestamp); 
    }

    function cancelUserLoan() external nonReentrant {
        UserLoan storage loan = userLoans[msg.sender]; 
        require(!loan.isActive, "Cannot cancel an active loan"); 
        require(loan.lender == msg.sender, "Only lender can cancel their loan"); 

        balanceOf[address(this)] -= loan.loanAmount; 
        balanceOf[msg.sender] += loan.loanAmount; 
        delete userLoans[msg.sender]; 

        emit UserLoanCancelled(msg.sender); 
    }

    function transferRewardPoolToReserve(uint256 amount) external onlyOwner {
        require(amount <= rewardPool, "Insufficient tokens in reward pool"); 

        uint256 fee = (amount * 1) / 100; 
        uint256 amountAfterFee = amount - fee; 

        rewardPool -= amount; 
        reserveTokens += amountAfterFee; 
        balanceOf[owner] += fee; 

        emit Transfer(address(this), owner, fee); 
    }

    function transferReserveToRewardPool(uint256 amount) external onlyOwner {
        require(amount <= reserveTokens, "Insufficient tokens in reserve"); 

        uint256 fee = (amount * 1) / 100; 
        uint256 amountAfterFee = amount - fee; 

        reserveTokens -= amount; 
        rewardPool += amountAfterFee; 
        balanceOf[owner] += fee;

        emit Transfer(address(this), owner, fee);
    }

    receive() external payable {
        reserveETH += msg.value;
    }

    fallback() external payable {
        reserveETH += msg.value;
    }
}
