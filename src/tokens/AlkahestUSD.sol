// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IAlkahestUSD} from "../interfaces/IAlkahestUSD.sol";
import {IERC3156FlashBorrower} from "../interfaces/IERC3156.sol";

/**
 * @title AlkahestUSD (AUSD)
 * @author ZengLLQ
 * @notice Sovereign synthetic dollar token with EIP-2612 permit and ERC-3156 flash minting.
 */
contract AlkahestUSD is IAlkahestUSD {
    string public constant name = "Alkahest USD";
    string public constant symbol = "AUSD";
    uint8 public constant decimals = 18;

    uint256 public override totalSupply;
    mapping(address => uint256) public override balanceOf;
    mapping(address => mapping(address => uint256)) public override allowance;

    address public owner;
    mapping(address => bool) public override isMinter;
    mapping(address => bool) public override isBurner;

    // EIP-2612 Permit state
    bytes32 public override DOMAIN_SEPARATOR;
    mapping(address => uint256) public override nonces;
    bytes32 public constant PERMIT_TYPEHASH =
        keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");

    // ERC-3156 Flash Mint configuration
    bytes32 private constant CALLBACK_SUCCESS = keccak256("ERC3156FlashBorrower.onFlashLoan");
    uint256 public flashMintCeiling = 10_000_000e18; // 10M AUSD max flash loan
    uint16 public flashFeeBps = 5; // 5 basis points (0.05%)
    uint256 public totalFlashFeeCollected;

    // Custom Errors
    error Unauthorized();
    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();
    error ExpiredDeadline();
    error InvalidSignature();
    error FlashLoanExceedsMax();
    error FlashLoanUnsupportedToken();
    error FlashLoanCallbackFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert Unauthorized();
        _;
    }

    constructor() {
        owner = msg.sender;
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256("EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"),
                keccak256(bytes(name)),
                keccak256(bytes("1")),
                block.chainid,
                address(this)
            )
        );
    }

    function setOwner(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        owner = newOwner;
    }

    function setMinter(address minter, bool status) external onlyOwner {
        if (minter == address(0)) revert ZeroAddress();
        isMinter[minter] = status;
        emit MinterUpdated(minter, status);
    }

    function setBurner(address burner, bool status) external onlyOwner {
        if (burner == address(0)) revert ZeroAddress();
        isBurner[burner] = status;
        emit BurnerUpdated(burner, status);
    }

    function setFlashMintConfig(uint256 ceiling, uint16 feeBps) external onlyOwner {
        flashMintCeiling = ceiling;
        flashFeeBps = feeBps;
    }

    function transfer(address to, uint256 value) external override returns (bool) {
        return _transfer(msg.sender, to, value);
    }

    function approve(address spender, uint256 value) external override returns (bool) {
        allowance[msg.sender][spender] = value;
        emit Approval(msg.sender, spender, value);
        return true;
    }

    function transferFrom(address from, address to, uint256 value) external override returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) {
            if (allowed < value) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = allowed - value;
            }
        }
        return _transfer(from, to, value);
    }

    function mint(address to, uint256 amount) external override {
        if (!isMinter[msg.sender] && msg.sender != owner) revert Unauthorized();
        if (to == address(0)) revert ZeroAddress();
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function burn(address from, uint256 amount) external override {
        if (!isBurner[msg.sender] && msg.sender != owner) revert Unauthorized();
        if (from == address(0)) revert ZeroAddress();
        uint256 bal = balanceOf[from];
        if (bal < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = bal - amount;
            totalSupply -= amount;
        }
        emit Transfer(from, address(0), amount);
    }

    function permit(address signer, address spender, uint256 value, uint256 deadline, uint8 v, bytes32 r, bytes32 s)
        external
        override
    {
        if (block.timestamp > deadline) revert ExpiredDeadline();
        bytes32 structHash = keccak256(abi.encode(PERMIT_TYPEHASH, signer, spender, value, nonces[signer]++, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", DOMAIN_SEPARATOR, structHash));
        address recovered = ecrecover(digest, v, r, s);
        if (recovered == address(0) || recovered != signer) revert InvalidSignature();

        allowance[signer][spender] = value;
        emit Approval(signer, spender, value);
    }

    // ERC-3156 Flash Mint implementation
    function maxFlashLoan(address token) external view override returns (uint256) {
        return token == address(this) ? flashMintCeiling : 0;
    }

    function flashFee(address token, uint256 amount) public view override returns (uint256) {
        if (token != address(this)) revert FlashLoanUnsupportedToken();
        return (amount * flashFeeBps) / 10000;
    }

    function flashLoan(IERC3156FlashBorrower receiver, address token, uint256 amount, bytes calldata data)
        external
        override
        returns (bool)
    {
        if (token != address(this)) revert FlashLoanUnsupportedToken();
        if (amount > flashMintCeiling) revert FlashLoanExceedsMax();

        uint256 fee = flashFee(token, amount);

        // 1. Mint flash amount to receiver
        totalSupply += amount;
        balanceOf[address(receiver)] += amount;
        emit Transfer(address(0), address(receiver), amount);

        // 2. Execute borrower callback
        if (receiver.onFlashLoan(msg.sender, token, amount, fee, data) != CALLBACK_SUCCESS) {
            revert FlashLoanCallbackFailed();
        }

        // 3. Repay loan + fee: transferFrom or burn from receiver
        uint256 totalRepay = amount + fee;
        uint256 receiverBal = balanceOf[address(receiver)];
        if (receiverBal < totalRepay) revert InsufficientBalance();

        unchecked {
            balanceOf[address(receiver)] = receiverBal - totalRepay;
            totalSupply -= amount; // Burn principal
            // Fee stays in supply / accumulated
            balanceOf[owner] += fee;
            totalFlashFeeCollected += fee;
        }
        emit Transfer(address(receiver), address(0), amount);
        emit Transfer(address(receiver), owner, fee);

        return true;
    }

    function _transfer(address from, address to, uint256 value) internal returns (bool) {
        if (to == address(0)) revert ZeroAddress();
        uint256 fromBal = balanceOf[from];
        if (fromBal < value) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = fromBal - value;
            balanceOf[to] += value;
        }
        emit Transfer(from, to, value);
        return true;
    }
}
