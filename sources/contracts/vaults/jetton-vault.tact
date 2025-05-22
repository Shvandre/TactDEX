import "../core/amm-pool";
import "../math";
import "./vault-interface";
import "../core/messages.tact";
// for compilation
import "./ton-vault.tact";
import "./proofs/check-proof";
import "./proofs/tep-89-proofer";
import "../core/liquidity-deposit";
import "../utils/utils";

// TEP-74 JettonNotify, but with forwardPayload serialized as expected fields
message(0x7362d09c) JettonNotifyWithActionRequest {
    queryId: Int as uint64;
    amount: Int as coins;
    sender: Address;
    eitherBit: Bool; // Should be 0, so other fields are stored inline
    actionOpcode: Int as uint32;
    actionPayload: Cell; // Obligatory ref
    proofType: Int as uint8; // 0 - No proof attached, 1 - TEP-89, 2 - StateInit, 3 - State, 4 - Jetton Burn
    proof: Slice as remaining;
}

// TEP-74 JettonTransfer with better DEX naming
message(0xf8a7ea5) SendViaJettonTransfer {
    queryId: Int as uint64;
    amount: Int as coins;
    destination: Address;
    responseDestination: Address?;
    customPayload: Cell?;
    forwardTonAmount: Int as coins;
    forwardPayload: Slice as remaining;
}

// TODO: Kind of hack for now, blocked by https://github.com/tact-lang/tact/issues/2496
asm fun saveState(jettonWallet: Address?, jettonMaster: Address) {
    NEWC
    STSLICE
    STSLICE
    ENDC
    c4 POP
}

// First sender proves that it sent the correct jetton via attaching the jetton master init state
contract JettonVault(
    jettonMaster: Address,
    jettonWallet: Address?, // Should be deployed with null
) with VaultInterface {
    receive(msg: JettonNotifyWithActionRequest) {
        if (self.jettonWallet == null) {
            // This function proofs that jetton wallet is valid
            // This function throws if proof is invalid and tries to send Jettons back
            let proofCheckRes = checkProof(self.jettonMaster, msg.proofType, msg.proof, msg.toCell());

            // Proof is not valid, or not supported, let's try to send jettons back
            if (!proofCheckRes) {
                message(MessageParameters {
                    mode: SendRemainingValue | SendIgnoreErrors,
                    body: SendViaJettonTransfer {
                        queryId: msg.queryId,
                        amount: msg.amount,
                        destination: msg.sender,
                        responseDestination: msg.sender,
                        customPayload: null,
                        forwardTonAmount: 0,
                        forwardPayload: sliceWithOneZeroBit(),
                    }.toCell(),
                    value: 0,
                    to: sender(),
                    bounce: true,
                });
                commit();
                require(false, "JettonVault: Proof is invalid");
            }
            self.jettonWallet = sender();

            // There is no sense to bounce, as Jettons won't be sent back
            // However, we can save jettonWallet address to the storage, as the proof succeeded
            saveState(self.jettonWallet, self.jettonMaster);
            commit();
        }
        // Maybe someone messed up with address, so let's try to send jettons back
        if (sender() != self.jettonWallet) {
            message(MessageParameters {
                mode: SendRemainingValue | SendIgnoreErrors,
                body: SendViaJettonTransfer {
                    queryId: msg.queryId,
                    amount: msg.amount,
                    destination: msg.sender,
                    responseDestination: msg.sender,
                    customPayload: null,
                    forwardTonAmount: 0,
                    forwardPayload: sliceWithOneZeroBit(),
                }.toCell(),
                value: 0,
                to: sender(),
                bounce: true,
            });
            commit();
            require(false, "JettonVault: Sender must be jetton wallet");
        }
        actionHandler(msg);
    }

    // We will receive this message only if TEP-89 proofer will successfully validate jettonWallet
    receive(msg: TEP89ProofResponse) {
        let prooferStateInit = initOf TEP89Proofer(self.jettonMaster, myAddress(), msg.proofedJettonWallet, msg.action);
        require(prooferStateInit.hasSameBasechainAddress(sender()), "JettonVault: Sender must be a valid proofer");
        self.jettonWallet = msg.proofedJettonWallet;
        actionHandler(JettonNotifyWithActionRequest.fromCell(msg.action));
    }

    receive() {}

    override fun handlePayout(msg: PayoutFromPool) {
        let sortedAddresses = sortAddresses(myAddress(), msg.otherVault);
        let poolInit = initOf AmmPool(sortedAddresses.lower, sortedAddresses.higher, 0, 0, 0, null);

        require(poolInit.hasSameBasechainAddress(sender()), "JettonVault: Sender must be pool");

        message(MessageParameters {
            to: self.jettonWallet!!,
            value: 0,
            mode: SendRemainingValue,
            body: SendViaJettonTransfer {
                queryId: 0,
                amount: msg.amount,
                responseDestination: msg.receiver,
                destination: msg.receiver,
                // TODO: We probably want to maximize forwardTonAmount, or user should specify it.....
                forwardTonAmount: 1,
                forwardPayload: beginCell().storeMaybeRef(msg.payloadToForward).endCell().beginParse(),
                customPayload: null,
            }.toCell(),
        });
    }

    get fun inited(): Bool {
        return self.jettonWallet != null;
    }

    get fun jettonWallet(): Address? {
        return self.jettonWallet;
    }
}

inline fun actionHandler(msg: JettonNotifyWithActionRequest) {
    if (msg.actionOpcode == SwapRequestOpcode) {
        handleSwapRequest(msg, SwapRequest.fromCell(msg.actionPayload));
        return;
    } else if (msg.actionOpcode == LPDepositPartOpcode) {
        handleLPDepositPart(msg, LPDepositPart.fromCell(msg.actionPayload));
        return;
    }

    require(false, "JettonVault: Invalid action opcode");
}

inline fun handleSwapRequest(msg: JettonNotifyWithActionRequest, action: SwapRequest) {
    message(MessageParameters {
        value: 0,
        bounce: false,
        mode: SendRemainingValue,
        to: action.pool,
        body: SwapIn {
            // If receiver is not specified, then it will be the sender of TONs or Jettons
            swapOutReceiver: action.receiver != null ? action.receiver!! : msg.sender,
            amount: msg.amount,
            isExactOutType: action.isExactOutType,
            limit: action.limit,
            timeout: action.timeout,
            payloadOnSuccess: action.payloadOnSuccess,
            payloadOnFailure: action.payloadOnFailure,
            nextStep: action.nextStep,
        }.toCell(),
    });
}

inline fun handleLPDepositPart(msg: JettonNotifyWithActionRequest, action: LPDepositPart) {
    message(MessageParameters {
        to: action.liquidityDepositContract,
        value: 0,
        mode: SendRemainingValue,
        body: PartHasBeenDeposited {
            depositor: msg.sender,
            amount: msg.amount,
            additionalParams: action.additionalParams,
        }.toCell(),
    });
}
