import "./liquidityDeposit";
import "./utils/utils";
import "./jettons/utils";
import "./jettons/jetton-wallet";

message(0xac2f5a38) SwapIn {
    amount: Int as uint256;
    minAmountOut: Int as uint256;
    timeout: Int as uint32; // Absolute unix timestamp
    swapOutReceiver: Address;
}

message(0x74f7a60) PayoutFromPool {
    otherVault: Address; // For proofing purposes
    amount: Int as uint256;
    receiver: Address;
}

message(0x6752aa52) LiquidityDeposit {
    leftAmount: Int as uint256;
    rightAmount: Int as uint256;
    depositor: Address;
    contractId: Int as uint64;
}

// JettonBurnNotification
message(0x7bdd97de) LiquidityWithdrawViaBurnNotification {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
}

// For LP tokens minting
message(0x178d4519) MintViaJettonTransferInternal {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    responseDestination: Address?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

contract AmmPool(
    leftVault: Address,
    rightVault: Address, // To be deterministic, rightVault address must be greater than leftVault address
    leftSideReserve: Int as uint256, // Should be deployed with 0
    rightSideReserve: Int as uint256, // Should be deployed with 0
    // LP tokens-related fields
    totalSupply: Int as coins, // Should be deployed with 0
) {
    receive() {}

    receive(msg: LiquidityDeposit) {
        let liquidityDepositContractInit = initOf LiquidityDepositContract(
            self.leftVault,
            self.rightVault,
            msg.leftAmount,
            msg.rightAmount,
            msg.depositor,
            msg.contractId,
            0,
        );

        require(liquidityDepositContractInit.hasSameBasechainAddress(sender()), "Liquidity provider should be liquidity contract");
        require(msg.leftAmount > 0, "You can't add 0 tokens on one side");

        let leftSideReceived = msg.leftAmount;
        let rightSideReceived = msg.rightAmount;
        // Both sides are 0 in this case.
        if (self.leftSideReserve == 0) {
            // TODO: check bug here
            self.leftSideReserve = msg.leftAmount;
            self.rightSideReserve = msg.rightAmount;
        } else {
            // Liquidity provide contract does not allow to add 0 tokens on one side.
            // Probably the rate has changed, so we must return extra tokens.
            if (msg.rightAmount / msg.leftAmount > self.rightSideReserve / self.leftSideReserve) {
                let expectedRightAmount = muldiv(msg.leftAmount, self.rightSideReserve, self.leftSideReserve);
                rightSideReceived = expectedRightAmount;
                message(MessageParameters {
                    // TODO: think about the value here and in lp minting
                    value: context().value / 2,
                    mode: SendPayFwdFeesSeparately,
                    to: self.rightVault,
                    body: PayoutFromPool {
                        otherVault: self.leftVault,
                        amount: msg.rightAmount - expectedRightAmount,
                        receiver: msg.depositor,
                    }.toCell(),
                });
            } else {
                let expectedLeftAmount = muldiv(msg.rightAmount, self.leftSideReserve, self.rightSideReserve);
                leftSideReceived = expectedLeftAmount;
                message(MessageParameters {
                    value: context().value / 2,
                    mode: SendPayFwdFeesSeparately,
                    to: self.leftVault,
                    body: PayoutFromPool {
                        otherVault: self.rightVault,
                        amount: msg.leftAmount - expectedLeftAmount,
                        receiver: msg.depositor,
                    }.toCell(),
                });
            }
        }

        // TODO Consider checking overflow
        let liquidityTokensToMint = sqrt(leftSideReceived * rightSideReceived);

        self.totalSupply += liquidityTokensToMint;

        // TODO: We should add custom payload to the messages
        let forwardPayload = beginCell().storeUint(0, 1).storeUint(0, 64).endCell().beginParse();
        checkEitherForwardPayload(forwardPayload);

        self.totalSupply += liquidityTokensToMint;

        // Mint LP tokens, amm pool acts as the jetton minter for lp jettons
        deploy(DeployParameters {
            value: context().value / 2 - 1,
            bounce: true,
            mode: SendPayFwdFeesSeparately,
            init: getJettonWalletInit(msg.depositor),
            body: MintViaJettonTransferInternal {
                queryId: 0,
                amount: liquidityTokensToMint,
                sender: myAddress(),
                responseDestination: msg.depositor,
                forwardTonAmount: 0, // TODO: We should maximize forwardTonAmount, and attach custom payload to the messages
                forwardPayload: forwardPayload,
            }.toCell(),
        });
    }

    receive(msg: LiquidityWithdrawViaBurnNotification) {
        let sender = parseStdAddress(sender().asSlice());
        let wallet = getJettonBasechainWalletByOwner(msg.sender);

        // Workchain 0 is basechain
        require(sender.workchain == Basechain && sender.address == wallet.hash!!, "Invalid sender of JettonBurn notification");

        let amountOfLeftToPay = muldiv(msg.amount, self.leftSideReserve, self.totalSupply);
        let amountOfRightToPay = muldiv(msg.amount, self.rightSideReserve, self.totalSupply);

        self.totalSupply -= msg.amount;
        let halfOfMsgValue = context().value / 2;

        // Preserve original balance (more, if we have storage debt)
        nativeReserve(myStorageDue(), ReserveAddOriginalBalance | ReserveExact);

        message(MessageParameters {
            to: self.leftVault,
            value: halfOfMsgValue,
            mode: SendDefaultMode | SendBounceIfActionFail,
            body: PayoutFromPool {
                otherVault: self.rightVault,
                amount: amountOfLeftToPay,
                receiver: msg.sender,
            }.toCell(),
        });

        message(MessageParameters {
            to: self.rightVault,
            value: 0,
            mode: SendRemainingBalance,
            body: PayoutFromPool {
                otherVault: self.leftVault,
                amount: amountOfRightToPay,
                receiver: msg.sender,
            }.toCell(),
        });
    }

    // TODO: Add TEP-89 Discoverable functionality

    const PoolFee: Int = 3; // 0.3%

    receive(msg: SwapIn) {
        let sender = sender();

        // We use require if situations that should never be possible
        require(sender == self.leftVault || sender == self.rightVault, "Sender must be a vault");

        let inVault = emptyAddress();
        let outVault = emptyAddress();
        let inBalance = 0;
        let outBalance = 0;
        let vaultOrderSwap = false;

        if (sender == self.leftVault) {
            inVault = self.leftVault;
            outVault = self.rightVault;
            inBalance = self.leftSideReserve;
            outBalance = self.rightSideReserve;
        } else {
            inVault = self.rightVault;
            outVault = self.leftVault;
            inBalance = self.rightSideReserve;
            outBalance = self.leftSideReserve;
            vaultOrderSwap = true;
        }

        // TODO: Need to add block functionality (for exact-time listings)

        if (inBalance == 0 || outBalance == 0) {
            returnFunds(msg.swapOutReceiver, outVault, msg.amount);
            require(false, "No liquidity in pool");
        }

        if (msg.timeout > 0 && now() > msg.timeout) {
            returnFunds(msg.swapOutReceiver, outVault, msg.amount);
            require(false, "Swap timeout");
        }

        // TODO: Test, that muldiv for msg.amount >= 0, 1000 - self.PoolFee >= 0 does not produce negative result
        // I couldn't check that in sources, cause there is very shitty c++ code that is impossible to read
        // So we just need to kinda fuzz it with corner cases
        let amountInWithFee = muldiv(msg.amount, 1000 - self.PoolFee, 1000);

        let newAmountIn = inBalance + amountInWithFee;
        let newAmountOut = muldiv(outBalance, inBalance, newAmountIn);
        let amountToPay = outBalance - newAmountOut;

        if (amountToPay < msg.minAmountOut) {
            returnFunds(msg.swapOutReceiver, outVault, msg.amount);
            require(false, "Amount out is less than minAmountOut");
        }

        message(MessageParameters {
            value: 0,
            mode: SendRemainingValue,
            to: outVault,
            body: PayoutFromPool {
                otherVault: inVault,
                amount: amountToPay,
                receiver: msg.swapOutReceiver,
            }.toCell(),
        });

        if (vaultOrderSwap) {
            self.leftSideReserve = newAmountOut;
            self.rightSideReserve = newAmountIn;
        } else {
            self.leftSideReserve = newAmountIn;
            self.rightSideReserve = newAmountOut;
        }
    }

    get fun getLeftSide(): Int {
        return self.leftSideReserve;
    }

    get fun getRightSide(): Int {
        return self.rightSideReserve;
    }

    get fun get_wallet_address(ownerAddress: Address): Address {
        return getJettonWalletByOwner(ownerAddress);
    }

    get fun expectedOut(vaultAddress: Address, amountIn: Int): Int {
        let inVault = emptyAddress();
        let outVault = emptyAddress();
        let inBalance = 0;
        let outBalance = 0;

        if (vaultAddress == self.leftVault) {
            inVault = self.leftVault;
            outVault = self.rightVault;
            inBalance = self.leftSideReserve;
            outBalance = self.rightSideReserve;
        } else {
            inVault = self.rightVault;
            outVault = self.leftVault;
            inBalance = self.rightSideReserve;
            outBalance = self.leftSideReserve;
        }
        let amountInWithFee = muldiv(amountIn, 1000 - self.PoolFee, 1000);
        let newAmountIn = inBalance + amountInWithFee;
        let newAmountOut = muldiv(outBalance, inBalance, newAmountIn);
        return outBalance - newAmountOut;
    }
}

inline fun returnFunds(receiver: Address, otherVault: Address, amount: Int) {
    message(MessageParameters {
        to: sender(),
        value: 0,
        mode: SendRemainingValue,
        body: PayoutFromPool {
            otherVault: otherVault,
            amount: amount,
            receiver: receiver,
        }.toCell(),
    });
    commit();
}

inline fun getJettonWalletInit(address: Address): StateInit {
    return initOf JettonWallet(0, address, myAddress());
}

inline fun getJettonWalletByOwner(jettonWalletOwner: Address): Address {
    return contractAddress(getJettonWalletInit(jettonWalletOwner));
}

inline fun getJettonBasechainWalletByOwner(jettonWalletOwner: Address): BasechainAddress {
    return contractBasechainAddress(getJettonWalletInit(jettonWalletOwner));
}
