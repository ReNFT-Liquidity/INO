pragma solidity ^0.5.16;

import 'openzeppelin-solidity-2.3.0/contracts/token/ERC20/IERC20.sol';
import 'openzeppelin-solidity-2.3.0/contracts/ownership/Ownable.sol';

import './UniTokenIno.sol';

contract TokenInoFactory is Ownable {
    // 募集币种合约地址
    address public collectTokenAddr;
    // 平台手续费币种合约地址
    address public platFeeTokenAddr;
    // 平台币合约地址
    address public platTokenAddr;
    // 平台手续费发送合约地址
    address public platFeeAddr;
    // 最小申购比例
    uint256 public minCollectAmountRate;
    // 申购开始结束时间最小间隔（默认1天）
    uint256 public inoDurationMin = 1 days;
    // 费率（手续费计算公式：手续费=总量*feeRateM/FEE_DIVIDE ）
    uint256 public constant FEE_DIVIDE = 1000000;
    uint256 public feeRateM = 500;

    // inoId -> inoAddr映射
    mapping(uint256 => address) public inoMap;

    //INO创建锁
    uint256 private _inoCreateLock = 0;

    // Events
    event LogSetInoDurationMin(address _executor, uint256 _inoDurationMin);
    event LogSetPlatFeeAddr(address _executor, address _oldAddr, address _newAddr);
    event LogCollectTokenAddr(address _executor, address _oldAddr, address _newAddr);
    event LogSetFeeRateM(address _executor, uint256 _oldRate, uint256 _newRate);
    event LogCreateIno(address _executor, uint256 _inoId, address _inoAddr, address _tokenAddr, address _nftAddr,
        uint256 _sTime, uint256 _eTime);

    function() external payable {}

    //Modifiers
    //用户结算专用：结算锁
    modifier inoCreateLock() {
        require(_inoCreateLock == 0, 'inoCreate is busy, try again later');
        _inoCreateLock = 1;
        _;
        _inoCreateLock = 0;
    }

    // API 1.1
    constructor(address _collectTokenAddr, address _platFeeTokenAddr, address _platTokenAddr, address _platFeeAddr,
        uint256 _feeRateM, uint256 _minCollectAmountRate) Ownable() public {
        require(_collectTokenAddr != address(0), 'address _collectTokenAddr cannot be null');
        require(_platFeeTokenAddr != address(0), 'address _platFeeTokenAddr cannot be null');
        require(_platTokenAddr != address(0), 'address _platTokenAddr cannot be null');
        require(_platFeeAddr != address(0), 'address _platFeeAddr cannot be null');
        require(_feeRateM > 0, '_feeRateM cannot be null');
        require(_minCollectAmountRate > 0, '_minCollectAmountRate cannot be less than 0');

        collectTokenAddr = _collectTokenAddr;
        platFeeTokenAddr = _platFeeTokenAddr;
        platTokenAddr = _platTokenAddr;
        platFeeAddr = _platFeeAddr;
        minCollectAmountRate = _minCollectAmountRate;
        feeRateM = _feeRateM;
    }

    ///// permissioned functions
    function setInoDurationMin(uint256 _inoDurationMin) external onlyOwner {
        require(inoDurationMin >0 , '_inoDurationMin must be more than 0');
        inoDurationMin = _inoDurationMin;
        emit LogSetInoDurationMin(msg.sender, _inoDurationMin);
    }
    // API 1.2
    function setPlatFeeAddr(address _platFeeAddr) external onlyOwner {
        require(_platFeeAddr != address(0), 'address cannot be null');
        address oldAddr = platFeeAddr;
        platFeeAddr = _platFeeAddr;
        emit LogSetPlatFeeAddr(msg.sender, oldAddr, _platFeeAddr);
    }

    // API 1.3
    function setCollectTokenAddr(address _collectTokenAddr) external onlyOwner {
        require(_collectTokenAddr != address(0), 'address cannot be null');
        address oldAddr = collectTokenAddr;
        collectTokenAddr = _collectTokenAddr;
        emit LogCollectTokenAddr(msg.sender, oldAddr, _collectTokenAddr);
    }

    // API EX. setFeeRate
    function setFeeRateM(uint8 _feeRateM) external onlyOwner {
        // feeRateM can be 0, and do not get fee when 0
        require(_feeRateM < FEE_DIVIDE, '_feeRateM mast less than FEE_DIVIDE');
        uint256 oldRate = feeRateM;
        feeRateM = _feeRateM;
        emit LogSetFeeRateM(msg.sender, oldRate, _feeRateM);
    }

    // API 1.6（调用用该方法前需用户approve转Token）
    function createIno(address _tokenAddr, address _nftAddr, uint256[8] calldata nums)
    external inoCreateLock returns (address inoAddr){
        uint256 _inoId = block.timestamp;
        require(inoMap[_inoId] == address(0), "createIno busy, try again later");
        //uint256 _sTime= nums[0];
        //uint256 _eTime= nums[1];
        //uint256 _lAmount= nums[2];
        //uint256 _lMinAmount= nums[3];
        //uint256 _tAmount= nums[4];
        //uint256 _tokenPrice= nums[5];
        //uint256 _minPerUser= nums[6];
        //uint256 _maxPerUser= nums[7];
        require(nums[3] >= SafeMath.div(SafeMath.mul(nums[2], minCollectAmountRate), 100),
            "nums[3] cannot be too low via minCollectAmountRate");
        //require(SafeMath.mul(nums[2], nums[5]) == nums[4], "nums[4] is invalid via calc");
        //创建合约
        bytes memory bytecode = type(UniTokenIno).creationCode;
        bytes32 salt = keccak256(abi.encodePacked(_inoId));
        assembly {
            inoAddr := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //初始化
        UniTokenIno ino = UniTokenIno(inoAddr);
        address pmAddr = msg.sender;
        address[7] memory inoAddrList = [_tokenAddr, _nftAddr, collectTokenAddr, platFeeTokenAddr, platTokenAddr, pmAddr,
        platFeeAddr];
        uint256[10] memory inoNums = [nums[0], nums[1], nums[2], nums[3], nums[5], nums[6], nums[7], feeRateM,
        FEE_DIVIDE, inoDurationMin];
        ino.inoConfig(_inoId, inoAddrList, inoNums);
        //PM质押token
        pmStakeInoToken(inoAddr, pmAddr, _tokenAddr, nums[2], nums[4], nums[5]);
        ino.inoConfig2(nums[4]);
        inoMap[_inoId] = inoAddr;
        //记录日志
        emit LogCreateIno(pmAddr, _inoId, inoAddr, _tokenAddr, _nftAddr, nums[0], nums[1]);
    }

    //项目方质押Token
    function pmStakeInoToken(address _inoAddr, address _pmAddr, address _tokenAddr,
        uint256 _lAmount, uint256 _tAmount, uint256 _tokenPrice) internal {
        require(_tAmount > 0, "Cannot stake 0");
        //must: 项目方未抵押过（不能多次抵押）
        //require(pmTokenAmount == 0, "pmTokenAmount has been initialized");
        //must:  _tokenUnit*_lAmount/_tokenPrice == _tAmount
        uint256 res2 = MySafeMath.div(MySafeMath.mul(_lAmount, UniTokenIno(_inoAddr).tokenPriceDiv()), _tokenPrice);
        //require(c2, "calc c2 failed");
        require(res2 == _tAmount, "_tAmount is invalid via calc");
        //must: 项目状态为1.未开始
        //require(_inoStatus == 1, "_inoStatus is invalid");
        //转账
        IERC20 token = IERC20(_tokenAddr);
        require(token.balanceOf(_pmAddr) >= _tAmount, "pmStakeInoToken fail of poor balance for pm");
        require(token.allowance(_pmAddr, address(this)) >= _tAmount,
            "pmStakeInoToken fail of poor allowance from pm to factory");
        require(token.transferFrom(_pmAddr, _inoAddr, _tAmount), "transfer token fail from pm");
        //pmTokenAmount = _tAmount;
    }

}