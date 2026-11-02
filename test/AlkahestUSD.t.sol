// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {AlkahestUSD} from "../src/tokens/AlkahestUSD.sol";
import {IERC3156FlashBorrower} from "../src/interfaces/IERC3156.sol";

contract MockFlashBorrower is IERC3156FlashBorrower {
    bool public shouldFail;

    function setShouldFail(bool _fail) external {
        shouldFail = _fail;
    }

    function onFlashLoan(address, address, uint256 amount, uint256 fee, bytes calldata)
        external
        override
        returns (bytes32)
    {
        if (shouldFail) {
            return bytes32(0);
        }
        // Borrower must have enough balance to cover amount + fee
        // In real arbitrage, borrower swaps and makes profit
        return keccak256("ERC3156FlashBorrower.onFlashLoan");
    }
}

contract AlkahestUSDTest is Test {
    AlkahestUSD public ausd;
    MockFlashBorrower public borrower;

    address public owner = address(this);
    address public alice = address(0x111);
    address public bob = address(0x222);
    uint256 internal signerPrivateKey = 0xA11CE;
    address internal signer;

    function setUp() public {
        signer = vm.addr(signerPrivateKey);
        ausd = new AlkahestUSD();
        borrower = new MockFlashBorrower();
    }

    function test_InitialState() public view {
        assertEq(ausd.name(), "Alkahest USD");
        assertEq(ausd.symbol(), "AUSD");
        assertEq(ausd.decimals(), 18);
        assertEq(ausd.totalSupply(), 0);
        assertEq(ausd.owner(), owner);
    }

    function test_MintAndBurnByOwner() public {
        ausd.mint(alice, 1000e18);
        assertEq(ausd.balanceOf(alice), 1000e18);
        assertEq(ausd.totalSupply(), 1000e18);

        ausd.burn(alice, 400e18);
        assertEq(ausd.balanceOf(alice), 600e18);
        assertEq(ausd.totalSupply(), 600e18);
    }

    function test_MintUnauthorizedReverts() public {
        vm.prank(bob);
        vm.expectRevert(AlkahestUSD.Unauthorized.selector);
        ausd.mint(bob, 500e18);
    }

    function test_TransferAndAllowance() public {
        ausd.mint(alice, 1000e18);

        vm.prank(alice);
        ausd.approve(bob, 300e18);
        assertEq(ausd.allowance(alice, bob), 300e18);

        vm.prank(bob);
        ausd.transferFrom(alice, bob, 200e18);
        assertEq(ausd.balanceOf(bob), 200e18);
        assertEq(ausd.balanceOf(alice), 800e18);
        assertEq(ausd.allowance(alice, bob), 100e18);
    }

    function test_EIP2612_Permit() public {
        uint256 value = 500e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = ausd.nonces(signer);

        bytes32 structHash = keccak256(abi.encode(ausd.PERMIT_TYPEHASH(), signer, bob, value, nonce, deadline));
        bytes32 digest = keccak256(abi.encodePacked("\x19\x01", ausd.DOMAIN_SEPARATOR(), structHash));

        (uint8 v, bytes32 r, bytes32 s) = vm.sign(signerPrivateKey, digest);

        ausd.permit(signer, bob, value, deadline, v, r, s);
        assertEq(ausd.allowance(signer, bob), value);
        assertEq(ausd.nonces(signer), 1);
    }

    function test_FlashMint_Success() public {
        uint256 flashAmount = 100_000e18;
        uint256 fee = ausd.flashFee(address(ausd), flashAmount); // 5 bps = 50 AUSD

        // Fund borrower with fee amount so it can repay principal + fee
        ausd.mint(address(borrower), fee);

        bool success = ausd.flashLoan(borrower, address(ausd), flashAmount, "");
        assertTrue(success);
        assertEq(ausd.totalFlashFeeCollected(), fee);
        assertEq(ausd.balanceOf(owner), fee);
    }

    function test_FlashMint_ExceedsCeilingReverts() public {
        uint256 excessiveAmount = 20_000_000e18; // > 10M ceiling
        vm.expectRevert(AlkahestUSD.FlashLoanExceedsMax.selector);
        ausd.flashLoan(borrower, address(ausd), excessiveAmount, "");
    }

    function test_FlashMint_CallbackFailureReverts() public {
        borrower.setShouldFail(true);
        vm.expectRevert(AlkahestUSD.FlashLoanCallbackFailed.selector);
        ausd.flashLoan(borrower, address(ausd), 1000e18, "");
    }
}
