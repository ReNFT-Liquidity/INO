pragma solidity ^0.5.16;

import "openzeppelin-solidity-2.3.0/contracts/math/Math.sol";
import "openzeppelin-solidity-2.3.0/contracts/token/ERC20/SafeERC20.sol";
import "openzeppelin-solidity-2.3.0/contracts/utils/ReentrancyGuard.sol";
import "openzeppelin-solidity-2.3.0/contracts/lifecycle/Pausable.sol";
import "openzeppelin-solidity-2.3.0/contracts/ownership/Ownable.sol";


import "./libraries/UniswapV2Library.sol";
// Inheritance
import "./interfaces/IUniTokenIno.sol";


contract UniTokenIno is IUniTokenIno, Ownable, Pausable {
    using MySafeMath for uint256;
    using SafeERC20 for IERC20;

    /* ========== STATE VARIABLES ========== */
    //Token价格精度（小数点后4位）
    uint256 public tokenPriceDiv = 10000;

    //INO申购最小时间间隔
    uint256 public inoDurationMin;
    //申购项目ID（INO幂等Id）
    uint256 public inoId;

    //平台方手续费及项目方最终拿走币种的地址（WETH）
    IERC20 public feeToken;
    //项目方提供进行INO的币种的地址（Token）
    IERC20 public inoToken;
    //项目方提供进行INO的NFT币种的地址（NFT）
    address public inoTargetToken;
    //募集币种（用户抵押及花费币种）的地址（LP）
    IUniswapV2Pair public collectToken;
    //平台币合约地址
    IERC20 public platTokenAddr;
    //平台手续费接收地址
    address private feeToAddr;
    //平台手续费率：乘数
    uint256 public feeRateM;
    //平台手续费率：除数
    uint256 public feeRateDivide;
    //平台手续费
    uint256 public feeAmount;
    //项目方钱包地址
    address public pmAddr;
    //项目方抵押（进行INO）的币种金额
    uint256 public pmTokenAmount;
    //每个Token能募集多少LP
    uint256 public tokenPrice;
    //每个用户最小申购数量
    uint256 public minPerUser;
    //每个用户最大申购数量
    uint256 public maxPerUser;
    //待募集的LP总量
    uint256 public amountToCollect;
    //待募集的LP最小量
    uint256 public minAmountToCollect;
    //募集的LP结算量
    uint256 public settleAmountToCollect;
    //已募集的LP总量
    uint256 public amountCollected;
    //募集后剩余的LP总量
    uint256 public amountCollectedBalance;
    //募集开始时间
    uint256 public collectStartTime;
    //募集结束时间
    uint256 public collectEndTime;
    //项目申购状态（1.未开始，2.申购中，3.申购结束，4.项目INO成功，5.项目INO失败）
    uint256 private _inoStatus = 1;
    //燃烧出来的平台币
    uint256 platTokenBurnoutAmount;
    //燃烧出来的收益币
    uint256 feeTokenBurnoutAmount;

    //用户剩余待结算额度：用户待购买token总数
    uint256 settleBuyTokenAmt;
    //用户剩余待结算额度：用户待花费LP总数
    uint256 settleSpendCollectAmt;
    //用户剩余待结算额度：用户待退还LP总数
    uint256 settleRepayCollectAmt;
    //用户剩余待结算额度：用户待退还平台币总数
    uint256 settleRepayPlatAmt;

    //锁
    //锁：用户锁仓同步锁
    uint256 private _userStakeLock;
    //锁：项目方结算同步锁
    uint256 private _pmSettleLock;
    //锁：用户结算同步锁
    uint256 private _userSettleLock;

    //用户申购账户
    mapping(address => UserAccount) public userAccountMap;


    /* ========== CONSTRUCTOR ========== */
    constructor() public {
        transferOwnership(msg.sender);
        //addPauser(msg.sender);
    }

    /* ========== STRUCTS ========== */
    struct UserAccount {
        //用户地址
        address userAddr;
        //用户质押总额
        uint256 stakingTotalAmount;
        //用户购买消耗金额
        uint256 spendAmount;
        //用户购买得到的token数量
        uint256 buyTokenAmount;
        //用户结算要退还的LP数量（记录，不论是否已退还）
        uint256 settleBackLpAmount;
        //用户结算要退还的平台币数量（记录，不论是否已退还）
        uint256 settleBackPlatAmount;
        //账户状态（1-已质押，2-已结算，3-已提币）
        uint256 accountStatus;
    }

    /* ========== MODIFIERS ========== */
    modifier onlyPm() {
        require(msg.sender == pmAddr, 'TokenIno::onlyPm: is not pm');
        _;
    }

    //用户锁仓方法专用：排队锁仓
    modifier userStakeByQueue() {
        require(_userStakeLock == 0, 'staking is busy, try again later');
        _userStakeLock = 1;
        _;
        _userStakeLock = 0;
    }

    //项目方结算方法专用：结算锁
    modifier pmSettleLock() {
        require(_pmSettleLock == 0, 'pmSettle is doing, please wait');
        _pmSettleLock = 1;
        _;
        _pmSettleLock = 0;
    }

    //用户结算专用：结算锁
    modifier userSettleLock() {
        require(_userSettleLock == 0, 'usrSettle is busy, try again later');
        _userSettleLock = 1;
        _;
        _userSettleLock = 0;
    }

    /* ========== EVENTS ========== */
    event LogInoConfig(address _caller, uint256 _inoId, uint256 _tokenPrice, uint256 _lAmount, uint256 _sTime, uint256 _eTime);
    //_userAddr: 用户地址
    //_lAmount: 新增质押金额
    //_transSuccess: 转账成功
    //_bookSuccess: 记账成功
    event LogUserStakeCollectToken(address _userAddr, uint256 _lAmount);
    event LogPmStakeInoToken(address _pmAddr, uint256 _tAmount);
    event LogPmSettleSuccess(address _caller, uint256 _amountCollected, uint256 _collectBurnoutFee,
        uint256 _feeAmount, uint256 _pmInoTokenRepay);
    event LogPmSettleFail(address _caller);
    event LogUserSettleSuccess(address _caller, uint256 _spendLp, uint256 _tokenBuy, uint256 _repayLp,
        uint256 _repayPlatToken, uint256 _settleBuyTokenAmt, uint256 _settleSpendCollectAmt,
        uint256 _settleRepayCollectAmt, uint256 _settleRepayPlatAmt);
    event LogUserSettleFail(address _caller, uint256 _repayLp);
    event LogLynnDebug(uint256 _flag);
    //event LogInoConfig2(address _caller, uint256 inoId);

    /* ========== VIEWS ========== */
    function getCachedInoStatus() external view returns (uint256){
        return _inoStatus;
    }

    //2.8、【查询】查询指定用户募集Token数
    function getUserTokenAmount() external view returns (uint256 userTokenAmount){
        return userAccountMap[msg.sender].buyTokenAmount;
    }

    //2.9、【查询】查询所有用户募集Token数
    function getTotalTokenAmount() external view returns (uint256 totalTokenAmount){
        return _inoStatus == 4 ? pmTokenAmount : 0;
    }

    //2.11、【查询】查询用户待提币额度
    //uint256 buyTokenAmount：用户购买得到的token数量;
    //uint256 settleBackLpAmount：用户结算已退还的LP数量;
    //uint256 settleBackPlatAmount：用户结算已退还的平台币数量;
    function getUserSettledAmount() external view returns (uint256 buyTokenAmount, uint256 settleBackLpAmount,
        uint256 settleBackPlatAmount){
        UserAccount storage uAccount = userAccountMap[msg.sender];
        if (uAccount.accountStatus != 3) {
            return (0, 0, 0);
        }
        return (uAccount.buyTokenAmount, uAccount.settleBackLpAmount, uAccount.settleBackPlatAmount);
    }

    /* ========== MUTATIVE FUNCTIONS ========== */
    function inoConfig(uint256 _inoId, address[7] calldata addrs, uint256[10] calldata nums) external onlyOwner {
        require(_inoId > 0, "_inoId cannot be 0");
        require(addrs.length == 7, "addrs length is invalid");
        require(nums.length == 10, "nums length is invalid");
        /*address _targetTokenAddr = addrs[1];
        address _collectTokenAddr = addrs[2];
        address _feeTokenAddr = addrs[3];
        address _platTokenAddr = addrs[4];
        address _pmAddr = addrs[5];
        address _feeToAddr = addrs[6];
        uint256 _sTime = nums[0];
        uint256 _eTime = nums[1];
        uint256 _lAmount = nums[2];
        uint256 _lMinAmount = nums[3];
        uint256 _tokenPrice = nums[4];
        uint256 _minPerUser = nums[5];
        uint256 _maxPerUser = nums[6];
        uint256 _feeRateM = nums[7];
        uint256 _feeRateDivide = nums[8];
        uint256 _inoDurationMin = nums[9];*/

        require(addrs[0] != address(0), "addrs[0] cannot be null");
        require(addrs[1] != address(0), "addrs[1] cannot be null");
        require(addrs[2] != address(0), "addrs[2] cannot be null");
        require(addrs[3] != address(0), "addrs[3] cannot be null");
        require(addrs[4] != address(0), "addrs[4] cannot be null");
        require(addrs[5] != address(0), "addrs[5] cannot be null");
        require(addrs[6] != address(0), "addrs[6] cannot be null");
        require(nums[0] > block.timestamp, "nums[0] cannot be less than now");
        require(nums[9] > 0, "nums[9] must be more than 0");
        require(nums[1] >= nums[0] + nums[9], "nums[1] cannot be less than nums[0]+nums[9]");
        require(nums[2] > 0, "nums[2] must be more than 0");
        require(nums[2] % (tokenPriceDiv * tokenPriceDiv) == 0, "nums[2] decimal too low");
        require(nums[3] > 0, "nums[3] must be more than 0");
        require(nums[3] % (tokenPriceDiv * tokenPriceDiv) == 0, "nums[3] decimal too low");
        require(nums[3] <= nums[2], "nums[3] must be no more than nums[2]");
        require(nums[4] > 0, "nums[4] must be more than 0");
        require(nums[7] == 0 || (nums[7] > 0 && nums[8] > 0), "nums[8] must be more than 0");

        inoId = _inoId;
        inoToken = IERC20(addrs[0]);
        inoTargetToken = addrs[1];
        collectToken = IUniswapV2Pair(addrs[2]);
        feeToken = IERC20(addrs[3]);
        platTokenAddr = IERC20(addrs[4]);
        pmAddr = addrs[5];
        feeToAddr = addrs[6];
        collectStartTime = nums[0];
        collectEndTime = nums[1];
        amountToCollect = nums[2];
        minAmountToCollect = nums[3];
        tokenPrice = nums[4];
        minPerUser = nums[5];
        maxPerUser = nums[6];
        feeRateM = nums[7];
        feeRateDivide = nums[8];
        inoDurationMin = nums[9];

        emit LogInoConfig(msg.sender, _inoId, nums[4], nums[2], nums[0], nums[1]);
    }

    function inoConfig2(uint256 _tAmount) external onlyOwner {
        _updateInoStatusForTime();
        //must: 项目方未抵押过（不能多次抵押）
        require(pmTokenAmount == 0, "pmTokenAmount has been initialized");
        require(inoToken.balanceOf(address(this)) == _tAmount,
            "the token balance of ino contract not equal _tAmount");
        pmTokenAmount = _tAmount;
        emit LogPmStakeInoToken(pmAddr, _tAmount);
    }

    //internal
    function _updateInoStatusForTime() internal {
        if (_inoStatus == 1 && block.timestamp > collectStartTime && block.timestamp < collectEndTime) {
            //未开始->申购中
            _inoStatus = 2;
        } else if (_inoStatus == 2 && block.timestamp >= collectEndTime) {
            //申购中->申购结束
            _inoStatus = 3;
        } else if (_inoStatus == 1 && block.timestamp >= collectEndTime) {
            _inoStatus = 3;
        }
    }

    //用户申购质押（调用用该方法前需用户approve转LP）
    function userStakeCollectToken(uint256 _lAmount) external whenNotPaused userStakeByQueue {
        //判断入参
        require(_lAmount >= Math.max(minPerUser, 0), "Cannot stake too little");
        //单次上限
        require(maxPerUser == 0 || _lAmount <= Math.min(maxPerUser, amountToCollect), "Cannot stake so much");
        UserAccount storage accountInfo = userAccountMap[msg.sender];
        //总额上限
        uint256 res = MySafeMath.add(accountInfo.stakingTotalAmount, _lAmount);
        require(maxPerUser == 0 || res < maxPerUser, "Cannot stake so much");
        //判断项目INO申购状态
        _updateInoStatusForTime();
        require(_inoStatus == 2, "inoStatus invalid");
        require(collectToken.balanceOf(msg.sender) >= _lAmount, "userStakeCollectToken fail: balance not enough");
        require(collectToken.allowance(msg.sender, address(this)) >= _lAmount,
            "userStakeCollectToken fail of poor allowance to ino");
        //调用者转账到合约地址
        bool _transSuccess = collectToken.transferFrom(msg.sender, address(this), _lAmount);
        if (!_transSuccess) {
            require(_transSuccess, "transfer from user fail");
        }
        //转账成功再记录
        if (accountInfo.userAddr == address(0)) {
            //不存在则初始化
            accountInfo.userAddr = msg.sender;
            accountInfo.stakingTotalAmount = _lAmount;
            accountInfo.spendAmount = 0;
            accountInfo.buyTokenAmount = 0;
            accountInfo.settleBackLpAmount = 0;
            accountInfo.settleBackPlatAmount = 0;
            accountInfo.accountStatus = 1;
        } else {
            //userStakeByQueue修饰器，避免重入或递归攻击
            accountInfo.stakingTotalAmount = res;
        }
        amountCollected = MySafeMath.add(amountCollected, _lAmount);
        emit LogUserStakeCollectToken(msg.sender, _lAmount);
    }

    //项目方结算
    function pmSettle() external onlyPm whenNotPaused pmSettleLock {
        //must: 项目状态为3.申购结束
        _updateInoStatusForTime();
        require(_inoStatus == 3, "_inoStatus is invalid");
        //1.判断是否已达申购数量，否则失败并走退还流程
        if (amountCollected >= minAmountToCollect) {
            _pmInoSuccess();
        } else {
            _pmInoFail();
        }
    }

    //private：项目方INO成功
    function _pmInoSuccess() internal {
        require(amountCollected >= minAmountToCollect, "invalid settle call");
        //项目方INO成功处理：
        //1.项目方能拿走的LP：amountToCollect
        //2.更改INO结果为成功
        _inoStatus = 4;
        settleAmountToCollect = Math.min(amountCollected, amountToCollect);
        //3.用能拿走的LP进行Burn，获取Liquid池的两种币种
        (platTokenBurnoutAmount, feeTokenBurnoutAmount) = removeLiquidity(address(platTokenAddr), address(feeToken),
            settleAmountToCollect, 0, 0, address(this));
        require(platTokenBurnoutAmount > 0, "platTokenBurnoutAmount must be more than 0");
        require(feeTokenBurnoutAmount > 0, "feeTokenBurnoutAmount must be more than 0");
        require(feeToken.balanceOf(address(this)) >= feeTokenBurnoutAmount,
            "balance of feeToken must be more than feeTokenBurnoutAmount");
        //4.记录burn后剩余的LP，待用户拿取退还：amountCollected - settleAmountToCollect
        amountCollectedBalance = amountCollected - settleAmountToCollect;

        //初始化结算额度：用户待花费LP总数
        settleSpendCollectAmt = settleAmountToCollect;
        //初始化结算额度：用户待退还LP总数
        settleRepayCollectAmt = amountCollectedBalance;
        //初始化结算额度：用户待退还平台币总数
        settleRepayPlatAmt = platTokenBurnoutAmount;

        //5.转feeToken手续费给平台方并打印转账结果日志
        feeAmount = MySafeMath.div(MySafeMath.mul(feeRateM, feeTokenBurnoutAmount), feeRateDivide);
        if (feeAmount > 0) {
            require(feeToken.transfer(feeToAddr, feeAmount), "transfer feeAmount fail");
        }
        //6.转剩余的feeToken币给项目方
        uint256 collectBurnoutFee = feeTokenBurnoutAmount - feeAmount;
        require(collectBurnoutFee > 0, "collectBurnoutFee not enough");
        //require(feeToken.balanceOf(address(this))>=collectBurnoutFee, "feeToken balance not enough");
        if (collectBurnoutFee > 0) {
            require(feeToken.balanceOf(address(this)) >= collectBurnoutFee,
                "feeToken balance must be more than collectBurnoutFee");
            require(feeToken.transfer(pmAddr, collectBurnoutFee), "transfer collectBurnoutFee fail");
        }
        //7.转剩余的token币给项目方
        uint256 pmInoTokenRepay = 0;
        if (settleAmountToCollect < amountToCollect) {
            //项目方Token剩余量 = Token总量 - (已燃烧LP量 / (tokenPrice / tokenPriceDiv) )
            // = Token总量 - (已燃烧LP量 * tokenPriceDiv / tokenPrice )
            pmInoTokenRepay =
            MySafeMath.sub(pmTokenAmount,
                MySafeMath.div(MySafeMath.mul(settleAmountToCollect, tokenPriceDiv), tokenPrice));
            if (pmInoTokenRepay > 0) {
                require(inoToken.transfer(pmAddr, pmInoTokenRepay), "transfer pmInoTokenRepay fail");
            }
        }

        //初始化结算额度：用户待购买token总数
        settleBuyTokenAmt = MySafeMath.sub(pmTokenAmount, pmInoTokenRepay);

        //打印结算结果日志
        emit LogPmSettleSuccess(msg.sender, amountCollected, collectBurnoutFee, feeAmount, pmInoTokenRepay);
    }

    // **** REMOVE LIQUIDITY ****
    function removeLiquidity(
        address tokenA,
        address tokenB,
        uint liquidity,
        uint amountAMin,
        uint amountBMin,
        address toAddr
    ) private returns (uint amountA, uint amountB) {
        // send liquidity to pair
        require(collectToken.transfer(address(collectToken), liquidity), "transfer Lp to burn fail");
        // burn out
        (uint amount0, uint amount1) = IUniswapV2Pair(collectToken).burn(toAddr);
        //(address token0,) = UniswapV2Library.sortTokens(tokenA, tokenB);
        address token0 = IUniswapV2Pair(collectToken).token0();
        address token1 = IUniswapV2Pair(collectToken).token1();
        require(token0 == tokenA || token0 == tokenB, "token0 is invalid");
        require(token1 == tokenA || token1 == tokenB, "token1 is invalid");
        (amountA, amountB) = tokenA == token0 ? (amount0, amount1) : (amount1, amount0);
        require(amountA >= amountAMin, 'removeLiquidity: INSUFFICIENT_A_AMOUNT');
        require(amountB >= amountBMin, 'removeLiquidity: INSUFFICIENT_B_AMOUNT');
        return (amountA, amountB);
    }

    //private：项目方INO失败
    function _pmInoFail() internal {
        //项目方INO失败处理：
        //1.更改INO结果为失败
        _inoStatus = 5;

        //初始化结算额度：用户待购买token总数
        settleBuyTokenAmt = 0;
        //初始化结算额度：用户待花费LP总数
        settleSpendCollectAmt = 0;
        //初始化结算额度：用户待退还LP总数
        settleRepayCollectAmt = amountCollected;
        //初始化结算额度：用户待退还平台币总数
        settleRepayPlatAmt = 0;

        //2.退还项目方Token并打印退还结果日志
        inoToken.transfer(pmAddr, pmTokenAmount);
        emit LogPmSettleFail(msg.sender);
    }

    //用户结算
    function userSettle() external whenNotPaused userSettleLock {
        //must: 项目状态为4.项目INO成功或5.项目INO失败
        require(_inoStatus == 4 || _inoStatus == 5, "_inoStatus is invalid");
        UserAccount storage uAccount = userAccountMap[msg.sender];
        require(uAccount.accountStatus == 1, "has settled");
        //1.判断是否已达申购数量，否则失败并走退还流程
        if (_inoStatus == 4) {
            _userInoSuccess(uAccount);
        } else {
            _userInoFail(uAccount);
        }
    }

    //private：用户结算成功
    function _userInoSuccess(UserAccount storage uAccount) internal {
        //must: 项目状态为4.项目INO成功
        require(_inoStatus == 4, "_inoStatus is invalid");
        //用户staking资金不能超限
        if (minPerUser > 0 && uAccount.stakingTotalAmount < minPerUser) {
            _userInoFail(uAccount);
            return;
        }
        //项目方INO成功处理：
        //1.计算单用户募集量：
        //①用户花费LP=min( (结算总募集量*用户个人量/已募集总量), 用户个人量)
        uint256 maxSpendLp = MySafeMath.div(MySafeMath.mul(settleAmountToCollect, uAccount.stakingTotalAmount),
            amountCollected);
        uint256 spendLp = Math.min(maxSpendLp, uAccount.stakingTotalAmount);

        if (spendLp > settleSpendCollectAmt) {
            //花销LP失败，全额退还
            _userInoFail(uAccount);
            return;
        }

        //②用户募集Token数=用户花费LP/Token单价
        uint256 tokenBuy = MySafeMath.div(MySafeMath.mul(spendLp, tokenPriceDiv), tokenPrice);
        if (tokenBuy > settleBuyTokenAmt) {
            //购买Token失败，全额退还
            _userInoFail(uAccount);
            return;
        }

        //2.计算用户退还：
        //①用户退还LP=用户个人量-花费LP
        uint256 repayLp = MySafeMath.sub(uAccount.stakingTotalAmount, spendLp);
        //②用户退还“募集燃烧退还币(RNFT)”=用户花费LP*燃烧总退还RNFT量/总燃烧LP量
        uint256 repayPlatToken = MySafeMath.div(MySafeMath.mul(spendLp, platTokenBurnoutAmount), settleAmountToCollect);
        //3.购买、退还累计
        //累计购买Token数
        settleBuyTokenAmt = MySafeMath.sub(settleBuyTokenAmt, tokenBuy);
        //累计花费LP数
        settleSpendCollectAmt = MySafeMath.sub(settleSpendCollectAmt, spendLp);
        //累计退还LP数
        if (repayLp > settleRepayCollectAmt) {
            //不够退还时，能退多少算多少(settleRepayCollectAmt)，并设定累计待退还为0
            repayLp = settleRepayCollectAmt;
            settleRepayCollectAmt = 0;
        } else {
            settleRepayCollectAmt = MySafeMath.sub(settleRepayCollectAmt, repayLp);
        }
        //累计退还RNFT数
        if (repayPlatToken > settleRepayPlatAmt) {
            //不够退还时，能退多少算多少(settleRepayPlatAmt)，并设定累计待退还为0
            repayPlatToken = settleRepayPlatAmt;
            settleRepayPlatAmt = 0;
        } else {
            settleRepayPlatAmt = MySafeMath.sub(settleRepayPlatAmt, repayPlatToken);
        }
        //记账
        uAccount.spendAmount = spendLp;
        uAccount.buyTokenAmount = tokenBuy;
        uAccount.settleBackLpAmount = repayLp;
        uAccount.settleBackPlatAmount = repayPlatToken;
        uAccount.accountStatus = 3;
        //4.给用户转账
        //①退还LP并记录结果日志
        if (repayLp > 0) {
            require(collectToken.transfer(uAccount.userAddr, repayLp), "repayLp transfer fail");
        }
        //②退还“募集燃烧退还币(RNFT)”并记录结果日志
        if (repayPlatToken > 0) {
            require(platTokenAddr.transfer(uAccount.userAddr, repayPlatToken), "repayPlatToken transfer fail");
        }
        //③转Token并记录结果日志
        if (tokenBuy > 0) {
            require(inoToken.transfer(uAccount.userAddr, tokenBuy), "tokenBuy transfer fail");
        }
        emit LogUserSettleSuccess(msg.sender, spendLp, tokenBuy, repayLp, repayPlatToken, settleBuyTokenAmt,
            settleSpendCollectAmt, settleRepayCollectAmt, settleRepayPlatAmt);
    }

    //private：用户结算失败
    function _userInoFail(UserAccount storage uAccount) internal {
        //失败并走退还流程
        //0.需要未结算
        require(uAccount.accountStatus == 1, "has settled");
        //1.记账
        uint256 repayLp = uAccount.stakingTotalAmount;
        if (repayLp > settleRepayCollectAmt) {
            //不够退还时，能退多少算多少(settleRepayCollectAmt)
            repayLp = settleRepayCollectAmt;
            settleRepayCollectAmt = 0;
        }
        uAccount.spendAmount = 0;
        uAccount.buyTokenAmount = 0;
        uAccount.settleBackLpAmount = repayLp;
        uAccount.settleBackPlatAmount = 0;
        uAccount.accountStatus = 3;
        //2.退还
        require(collectToken.transfer(uAccount.userAddr, repayLp), "user settle fail repay fail");
        emit LogUserSettleFail(msg.sender, repayLp);
    }

    //紧急暂停
    function emergencyPauseIno() external onlyOwner whenNotPaused {
        pause();
    }

    //暂停恢复
    function unpauseIno() external onlyOwner whenPaused {
        unpause();
    }

}
