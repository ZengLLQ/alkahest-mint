// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IERC20} from "./IERC20.sol";
import {IERC3156FlashLender} from "./IERC3156.sol";

interface IAlkahestUSD is IERC20, IERC3156FlashLender {
    event MinterUpdated(address indexed minter, bool status);
    event BurnerUpdated(address indexed burner, bool status);

    function mint(address to, uint256 amount) external;
    function burn(address from, uint256 amount) external;
    function permit(address owner, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external;
    function nonces(address owner) external view returns (uint256);
    function DOMAIN_SEPARATOR() external view returns (bytes32);
    function isMinter(address account) external view returns (bool);
    function isBurner(address account) external view returns (bool);
}
