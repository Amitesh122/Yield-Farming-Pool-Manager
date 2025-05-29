// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/security/Pausable.sol";

/**
 * @title Yield Farming Pool Manager
 * @dev A smart contract that manages multiple yield farming pools and automatically 
 * allocates user funds to maximize returns across different DeFi protocols
 */
contract Project is ReentrancyGuard, Ownable, Pausable {
    
    // Constructor
    constructor() Ownable(msg.sender) {
        // Initialize contract with deployer as owner
    }
    
    // Structs
    struct Pool {
        address poolAddress;
        IERC20 stakingToken;
        uint256 totalStaked;
        uint256 rewardRate; // Annual percentage yield (APY) in basis points (100 = 1%)
        uint256 lastUpdateTime;
        bool isActive;
        string poolName;
    }
    
    struct UserInfo {
        uint256 totalDeposited;
        uint256 lastDepositTime;
        mapping(uint256 => uint256) poolAllocations; // poolId => amount allocated
        uint256 pendingRewards;
        uint256 rewardDebt;
    }
    
    // State variables
    mapping(uint256 => Pool) public pools;
    mapping(address => UserInfo) public userInfo;
    mapping(address => bool) public authorizedPools;
    
    uint256 public totalPools;
    uint256 public totalValueLocked;
    uint256 public managementFee = 200; // 2% in basis points
    uint256 public constant MAX_POOLS = 10;
    uint256 public constant BASIS_POINTS = 10000;
    
    // Events
    event PoolAdded(uint256 indexed poolId, address poolAddress, string poolName, uint256 rewardRate);
    event FundsDeposited(address indexed user, uint256 amount, uint256 timestamp);
    event FundsAllocated(address indexed user, uint256 poolId, uint256 amount);
    event RewardsHarvested(address indexed user, uint256 amount);
    event PoolUpdated(uint256 indexed poolId, uint256 newRewardRate, bool isActive);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    
    // Modifiers
    modifier validPool(uint256 _poolId) {
        require(_poolId < totalPools && pools[_poolId].isActive, "Invalid or inactive pool");
        _;
    }
    
    modifier hasDeposits(address _user) {
        require(userInfo[_user].totalDeposited > 0, "No deposits found");
        _;
    }
    
    /**
     * @dev Core Function 1: Deposit funds and automatically allocate across pools
     * @param _token The ERC20 token to deposit
     * @param _amount Amount of tokens to deposit
     */
    function depositAndAllocate(IERC20 _token, uint256 _amount) 
        external 
        nonReentrant 
        whenNotPaused 
    {
        require(_amount > 0, "Amount must be greater than 0");
        require(_token.balanceOf(msg.sender) >= _amount, "Insufficient balance");
        
        // Transfer tokens from user
        require(_token.transferFrom(msg.sender, address(this), _amount), "Transfer failed");
        
        // Update user info
        UserInfo storage user = userInfo[msg.sender];
        user.totalDeposited += _amount;
        user.lastDepositTime = block.timestamp;
        
        // Calculate and update pending rewards before allocation
        _updateUserRewards(msg.sender);
        
        // Auto-allocate funds across pools based on highest yield
        _autoAllocateFunds(msg.sender, address(_token), _amount);
        
        totalValueLocked += _amount;
        
        emit FundsDeposited(msg.sender, _amount, block.timestamp);
    }
    
    /**
     * @dev Core Function 2: Harvest rewards from all pools for a user
     * @param _user Address of the user to harvest rewards for
     */
    function harvestAllRewards(address _user) 
        external 
        nonReentrant 
        hasDeposits(_user) 
        returns (uint256 totalRewards) 
    {
        require(_user == msg.sender || msg.sender == owner(), "Unauthorized harvest");
        
        UserInfo storage user = userInfo[_user];
        
        // Update rewards from all pools where user has allocations
        for (uint256 i = 0; i < totalPools; i++) {
            if (user.poolAllocations[i] > 0 && pools[i].isActive) {
                uint256 poolRewards = _calculatePoolRewards(_user, i);
                totalRewards += poolRewards;
            }
        }
        
        // Add pending rewards
        totalRewards += user.pendingRewards;
        
        if (totalRewards > 0) {
            // Deduct management fee
            uint256 fee = (totalRewards * managementFee) / BASIS_POINTS;
            uint256 userRewards = totalRewards - fee;
            
            // Reset pending rewards
            user.pendingRewards = 0;
            user.rewardDebt = block.timestamp;
            
            // Transfer rewards to user (assuming rewards are in native token or specific reward token)
            // Note: In production, this would interact with actual pool contracts
            payable(_user).transfer(userRewards);
            
            emit RewardsHarvested(_user, userRewards);
        }
        
        return totalRewards;
    }
    
    /**
     * @dev Core Function 3: Rebalance user's portfolio across pools for optimal yield
     * @param _user Address of the user whose portfolio to rebalance
     */
    function rebalancePortfolio(address _user) 
        external 
        nonReentrant 
        hasDeposits(_user) 
    {
        require(_user == msg.sender || msg.sender == owner(), "Unauthorized rebalance");
        
        UserInfo storage user = userInfo[_user];
        
        // Harvest existing rewards first
        _updateUserRewards(_user);
        
        // Get current total allocation
        uint256 totalAllocation = user.totalDeposited;
        
        // Find the optimal allocation strategy
        uint256[] memory newAllocations = _calculateOptimalAllocation(totalAllocation);
        
        // Reallocate funds
        for (uint256 i = 0; i < totalPools; i++) {
            if (pools[i].isActive) {
                uint256 currentAllocation = user.poolAllocations[i];
                uint256 newAllocation = newAllocations[i];
                
                if (newAllocation != currentAllocation) {
                    user.poolAllocations[i] = newAllocation;
                    
                    // Update pool's total staked amount
                    if (newAllocation > currentAllocation) {
                        pools[i].totalStaked += (newAllocation - currentAllocation);
                    } else {
                        pools[i].totalStaked -= (currentAllocation - newAllocation);
                    }
                    
                    emit FundsAllocated(_user, i, newAllocation);
                }
            }
        }
    }
    
    // Admin Functions
    function addPool(
        address _poolAddress,
        address _stakingToken,
        uint256 _rewardRate,
        string memory _poolName
    ) external onlyOwner {
        require(totalPools < MAX_POOLS, "Maximum pools reached");
        require(_poolAddress != address(0), "Invalid pool address");
        require(!authorizedPools[_poolAddress], "Pool already exists");
        
        pools[totalPools] = Pool({
            poolAddress: _poolAddress,
            stakingToken: IERC20(_stakingToken),
            totalStaked: 0,
            rewardRate: _rewardRate,
            lastUpdateTime: block.timestamp,
            isActive: true,
            poolName: _poolName
        });
        
        authorizedPools[_poolAddress] = true;
        
        emit PoolAdded(totalPools, _poolAddress, _poolName, _rewardRate);
        totalPools++;
    }
    
    function updatePool(uint256 _poolId, uint256 _newRewardRate, bool _isActive) 
        external 
        onlyOwner 
        validPool(_poolId) 
    {
        Pool storage pool = pools[_poolId];
        pool.rewardRate = _newRewardRate;
        pool.isActive = _isActive;
        pool.lastUpdateTime = block.timestamp;
        
        emit PoolUpdated(_poolId, _newRewardRate, _isActive);
    }
    
    // Internal Functions
    function _autoAllocateFunds(address _user, address _token, uint256 _amount) internal {
        uint256[] memory allocations = _calculateOptimalAllocation(_amount);
        UserInfo storage user = userInfo[_user];
        
        for (uint256 i = 0; i < totalPools; i++) {
            if (allocations[i] > 0 && pools[i].isActive) {
                user.poolAllocations[i] += allocations[i];
                pools[i].totalStaked += allocations[i];
                
                emit FundsAllocated(_user, i, allocations[i]);
            }
        }
    }
    
    function _calculateOptimalAllocation(uint256 _totalAmount) internal view returns (uint256[] memory) {
        uint256[] memory allocations = new uint256[](totalPools);
        
        // Simple strategy: allocate more to higher-yielding pools
        uint256 totalWeight = 0;
        uint256[] memory weights = new uint256[](totalPools);
        
        for (uint256 i = 0; i < totalPools; i++) {
            if (pools[i].isActive) {
                weights[i] = pools[i].rewardRate;
                totalWeight += weights[i];
            }
        }
        
        if (totalWeight > 0) {
            for (uint256 i = 0; i < totalPools; i++) {
                if (pools[i].isActive) {
                    allocations[i] = (_totalAmount * weights[i]) / totalWeight;
                }
            }
        }
        
        return allocations;
    }
    
    function _calculatePoolRewards(address _user, uint256 _poolId) internal view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        Pool storage pool = pools[_poolId];
        
        if (user.poolAllocations[_poolId] == 0) return 0;
        
        uint256 timeStaked = block.timestamp - user.lastDepositTime;
        uint256 annualReward = (user.poolAllocations[_poolId] * pool.rewardRate) / BASIS_POINTS;
        
        return (annualReward * timeStaked) / 365 days;
    }
    
    function _updateUserRewards(address _user) internal {
        UserInfo storage user = userInfo[_user];
        uint256 totalPendingRewards = 0;
        
        for (uint256 i = 0; i < totalPools; i++) {
            if (user.poolAllocations[i] > 0) {
                totalPendingRewards += _calculatePoolRewards(_user, i);
            }
        }
        
        user.pendingRewards += totalPendingRewards;
    }
    
    // Emergency Functions
    function emergencyWithdraw() external nonReentrant hasDeposits(msg.sender) {
        UserInfo storage user = userInfo[msg.sender];
        uint256 totalToWithdraw = user.totalDeposited;
        
        // Reset user allocations
        for (uint256 i = 0; i < totalPools; i++) {
            if (user.poolAllocations[i] > 0) {
                pools[i].totalStaked -= user.poolAllocations[i];
                user.poolAllocations[i] = 0;
            }
        }
        
        user.totalDeposited = 0;
        user.pendingRewards = 0;
        totalValueLocked -= totalToWithdraw;
        
        // Transfer funds back to user
        payable(msg.sender).transfer(totalToWithdraw);
        
        emit EmergencyWithdraw(msg.sender, totalToWithdraw);
    }
    
    function pause() external onlyOwner {
        _pause();
    }
    
    function unpause() external onlyOwner {
        _unpause();
    }
    
    // View Functions
    function getUserInfo(address _user) external view returns (
        uint256 totalDeposited,
        uint256 pendingRewards,
        uint256[] memory allocations
    ) {
        UserInfo storage user = userInfo[_user];
        allocations = new uint256[](totalPools);
        
        for (uint256 i = 0; i < totalPools; i++) {
            allocations[i] = user.poolAllocations[i];
        }
        
        return (user.totalDeposited, user.pendingRewards, allocations);
    }
    
    function getPoolInfo(uint256 _poolId) external view returns (Pool memory) {
        return pools[_poolId];
    }
    
    // Fallback function to receive ETH
    receive() external payable {}
}
