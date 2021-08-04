pragma solidity >=0.5.0 <0.9.0;


interface IUniTokenIno {
    
    // Views
    function getTotalTokenAmount() external view returns (uint256 totalTokenAmount);

    function getCachedInoStatus() external view returns (uint256);

    function getUserSettledAmount() external view returns (uint256 buyTokenAmount, uint256 settleBackLpAmount,
        uint256 settleBackPlatAmount);

    // Mutative Functions
    function inoConfig(uint256 _inoId, address[7] calldata addrs, uint256[10] calldata nums) external;

    function userStakeCollectToken(uint256 _lAmount) external;

    function pmSettle() external;

    function userSettle() external;

    // emergency stop when the INO not end
    function emergencyPauseIno() external;

    function unpauseIno() external;

}