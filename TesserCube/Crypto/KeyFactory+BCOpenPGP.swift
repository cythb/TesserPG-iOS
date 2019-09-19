//
//  KeyFactory+BCOpenPGP.swift
//  TesserCube
//
//  Created by Cirno MainasuK on 2019-4-26.
//  Copyright © 2019 Sujitech. All rights reserved.
//

import Foundation
import ConsolePrint
import DMSGoPGP

// MARK: - Decrypt
extension KeyFactory {
    
    enum VerifyResult {
        case noSignature
        case valid
        case invalid
        case unknownSigner([String])    // unknown signer
    }

    struct DecryptResult {
        let message: String
        let signatureKey: TCKey?
        let recipientKeys: [TCKey]

        let verifyResult: VerifyResult
        let unknownRecipientKeyIDs: [String]

    }

    static var keys: [TCKey] {
        return ProfileService.default.keys.value
    }
    
    static func verify(armoredMessage: String) -> Bool {
        var verifyPGPMsgError: NSError?
        let _ = CryptoNewPGPMessageFromArmored(armoredMessage, &verifyPGPMsgError)
        if verifyPGPMsgError == nil {
            return true
        }
        
        var verifyClearTextError: NSError?
        let _ = CryptoNewClearTextMessageFromArmored(armoredMessage, &verifyClearTextError)
        if verifyClearTextError == nil {
            return true
        }
        return false
    }

    // swiftlint:disable cyclomatic_complexity
    /// Decrypt and verify the armored message & cleartext message.
    ///
    /// - Parameter armoredMessage: encrypted message
    /// - Returns: DecryptResult
    static func decryptMessage(_ armoredMessage: String) throws -> DecryptResult {
        // Message is cleartext signed message
        // Do not need decrypt, just return the body and signature
        var error: NSError?
        let clearMessage = CryptoNewClearTextMessageFromArmored(armoredMessage, &error)
        if error == nil, clearMessage != nil {
            // Armored message is a clear text message
            for key in keys {
                let originMessage = HelperVerifyCleartextMessage(key.goKeyRing, armoredMessage, CryptoGetGopenPGP()!.getUnixTime(), &error)
                if error == nil {
                    return DecryptResult(message: originMessage,
                                         signatureKey: key,
                                         recipientKeys: [],
                                         verifyResult: .valid,
                                         unknownRecipientKeyIDs: [])
                }
            }
        }

        do {
            let armoredMessage = armoredMessage.trimmingCharacters(in: .whitespacesAndNewlines)

            let secretKeys = keys
                .filter { $0.hasSecretKey }
            
            guard let pgpMessage = CryptoNewPGPMessageFromArmored(armoredMessage, &error) else {
                throw TCError.interpretError(reason: .badPayload)
            }
            
            // 5. Collect a keyID-password dict from KeyChain
            var keyPasswordDict = [String: String]()
            let possibleKeyIDs = secretKeys.compactMap { $0.longIdentifier }
            
            for keyChainItem in ProfileService.default.keyChain.allItems() {
                if let key = keyChainItem["key"] as? String, let password = keyChainItem["value"] as? String {
                    if possibleKeyIDs.contains(key) {
                        keyPasswordDict[key] = password
                    }
                }
            }
            
            // 1. Try to get all recipient IDs
            var knownRecipientKeyIDs: [String] = []
            var hiddenRecipientKeyIDs: [String] = []
            
            var signatureVerifyResult: VerifyResult = .invalid
            var signatureKey: TCKey?
            var signatureKeyID: String?
            for secretKey in secretKeys {
                if let passphrase = keyPasswordDict[secretKey.longIdentifier] {
                    try? secretKey.unlock(passphrase: passphrase)
                }
                var getMessageDetailError: NSError?
                do {
                    let messageDetail = try pgpMessage.getDetails(secretKey.goKeyRing)
                    if !messageDetail.isSigned {
                        signatureVerifyResult = .noSignature
                    } else {
                        signatureKeyID = messageDetail.signedByKeyId
                        if signatureKey == nil {
                            // Check the signature key
                            for pubkey in keys {
                                if pubkey.longIdentifier == messageDetail.signedByKeyId {
                                    signatureKey = pubkey
                                }
                            }
                        }
                    }
                    for recipientIndex in 0 ..< messageDetail.getEncryptedToKeyIdsCount() {
                        let keyID = messageDetail.getEncryptedToKeyId(recipientIndex, error: &getMessageDetailError)
                        if getMessageDetailError == nil {
                            if keyID.isHiddenRecipientID {
                                hiddenRecipientKeyIDs.append(keyID)
                            } else {
                                knownRecipientKeyIDs.append(keyID)
                            }
                        }
                    }
                    
                } catch {
                    print("Fail to get msg detail!, keyID: " + secretKey.userID)
                    print(error.localizedDescription)
                }
            }
            
            let knownRecipientKeyIDSet = Set(knownRecipientKeyIDs)
            
            // 2. Collect all encryptionKeyIDs
            let encryptionIDs = secretKeys.compactMap { $0.encryptionkeyID }
            
            // 3. If a keyRing's encryptionKeyID is equal to a receipientKeyID, add the TCKey to receipientKeys
            var recipientKeys = secretKeys.filter { knownRecipientKeyIDSet.contains($0.encryptionkeyID ?? "") }
            
            let availableRecipientKeyIDs = recipientKeys.compactMap { $0.encryptionkeyID }
            
            // 4. All rest recipient key IDs are unknown
            let unknownRecipientKeyIDs = Array(knownRecipientKeyIDSet.subtracting(encryptionIDs))
            
            if !hiddenRecipientKeyIDs.isEmpty {
                // For each hidden recipient encrypted data, check all possible keys to decrypt
                for _ in hiddenRecipientKeyIDs {
                    for possibleKey in secretKeys {
                        var attemptDecryptError: NSError?
                        _ = HelperDecryptMessageArmored(possibleKey.goKeyRing, keyPasswordDict[possibleKey.longIdentifier], armoredMessage, &attemptDecryptError)
                        if attemptDecryptError == nil, !availableRecipientKeyIDs.contains(possibleKey.encryptionkeyID ?? "") {
                            // If we find a new valid key ID, append the key to the recipientKeys
                            recipientKeys.append(possibleKey)
                        }
                    }
                }
                
            }
            
            if recipientKeys.isEmpty {
                // No valid keys found for either known or hidden recipient
                throw TCError.pgpKeyError(reason: .noAvailableDecryptKey)
            }
            
            
            // 6. Decryption message using any recipient key
            var decryptedMessage: String?
            let decryptKey = recipientKeys.first

            decryptedMessage = HelperDecryptMessageArmored(decryptKey!.goKeyRing, keyPasswordDict[decryptKey!.longIdentifier], armoredMessage, &error)
            
            var signatureVerifyError: NSError?
            let _ = HelperDecryptVerifyMessageArmored(signatureKey?.goKeyRing, decryptKey!.goKeyRing, keyPasswordDict[decryptKey!.longIdentifier], armoredMessage, &signatureVerifyError)

            if signatureVerifyError != nil {
                signatureVerifyResult = .invalid
            } else {
                if signatureKey == nil {
                    // TODO: return unknown signature keyID
                    signatureVerifyResult = .valid
                } else {
                    signatureVerifyResult = .valid
                }
            }
            
            if let decryptedMsg = decryptedMessage {
                return DecryptResult(message: decryptedMsg,
                                     signatureKey: signatureKey,
                                     recipientKeys: recipientKeys,
                                     verifyResult: signatureVerifyResult,
                                     unknownRecipientKeyIDs: unknownRecipientKeyIDs)
            } else {
                throw TCError.pgpKeyError(reason: .noAvailableDecryptKey)
            }
        } catch {
            throw error
        }
    }
    // swiftlint:enable cyclomatic_complexity
}

// MARK: - Clearsign & Encrypt
extension KeyFactory {

    /// Clearsign message
    ///
    /// - Parameters:
    ///   - message: raw message for sign
    ///   - signatureKey: signature key
    /// - Returns: cleartext formate message
    /// - Throws: invalid signature key or fail to retrieve password
    static func clearsignMessage(_ message: String, signatureKey: TCKey) throws -> String {
        guard signatureKey.hasPublicKey, signatureKey.hasSecretKey else {
            throw TCError.composeError(reason: .invalidSigner)
        }
//        let secretKeyRing = signatureKey.keyRing.secretKeyRing else {
//            throw TCError.composeError(reason: .invalidSigner)
//        }

        guard let password = try? ProfileService.default.keyChain
            .authenticationPrompt("Unlock secret key to sign message")
            .get(signatureKey.longIdentifier) else {
            throw TCError.composeError(reason: .keychainUnlockFail)
        }

        do {
            var error: NSError?
            let signedMessage = HelperSignCleartextMessageArmored(signatureKey.goKeyRing, password, message, &error)
            if let signError = error {
                throw signError
            }
            return signedMessage
//            let signer = try DMSPGPSigner(secretKeyRing: secretKeyRing, password: password)
//            return signer.sign(message: message)
        } catch {
            consolePrint(error)
            throw TCError.composeError(reason: .invalidSigner)
        }
    }

    /// Encrypt raw message to armored message. Create signnature if signatureKey not nil
    ///
    /// - Parameters:
    ///   - message: raw message for encrypt
    ///   - signatureKey: key for create signature
    ///   - recipients: recipients public key for encryption
    /// - Returns: armored encrypted message
    /// - Throws: empty recipients encrypt fail or sign fail (if signing)
    /// - Note: this method add signer to recipients when possible to prevent sender could not decrypt message
    static func encryptMessage(_ message: String, signatureKey: TCKey?, recipients: [TCKey]) throws -> String {
        guard !recipients.isEmpty else {
            throw TCError.composeError(reason: .emptyRecipients)
        }

        // Get password for signature key
        var signatureKeyPassword: String?
        if let signatureKey = signatureKey {
            guard signatureKey.hasPublicKey, signatureKey.hasSecretKey else {
                throw TCError.composeError(reason: .invalidSigner)
            }

            guard let password = try? ProfileService.default.keyChain
                .authenticationPrompt("Unlock secret key to sign message")
                .get(signatureKey.longIdentifier) else {
                throw TCError.composeError(reason: .keychainUnlockFail)
            }
            signatureKeyPassword = password
        }

        do {
            var error: NSError?
            var encrypted: String?
            var allRecipientsKeyRing = recipients.first?.goKeyRing
            for i in 1 ..< recipients.count {
                allRecipientsKeyRing = CryptoGopenPGP().combineKeyRing(allRecipientsKeyRing, keyRing2: recipients[i].goKeyRing)
            }
            if signatureKey?.hasSecretKey ?? false, let password = signatureKeyPassword {
                encrypted = HelperEncryptSignMessageArmored(allRecipientsKeyRing, signatureKey?.goKeyRing, password, message, &error)
            } else {
                encrypted = HelperEncryptMessageArmored(allRecipientsKeyRing, message, &error)
            }
            if let encryptError = error {
                throw encryptError
            }
            guard let encryptedMessage = encrypted else {
                throw TCError.composeError(reason: .internal)
            }
            return encryptedMessage
//            var encryptor: DMSPGPEncryptor
            // Add encryption key of signer if possible otherwise sender (a.k.a signer) could not decrypt message
//            if let secretKeyRing = signatureKey?.keyRing.secretKeyRing, let senderPublicKeyRing = signatureKey?.keyRing.publicKeyRing, let password = signatureKeyPassword {
//                let publicKeyDataList = recipients.map { DMSPGPEncryptor.PublicKeyData(publicKeyRing: $0.keyRing.publicKeyRing, isHidden: false)  } + [ DMSPGPEncryptor.PublicKeyData(publicKeyRing: senderPublicKeyRing, isHidden: false)]
//                encryptor = try DMSPGPEncryptor(publicKeyDataList: publicKeyDataList, secretKeyRing: secretKeyRing, password: password)
//            } else {
//                let publicKeyDataList = recipients.map { DMSPGPEncryptor.PublicKeyData(publicKeyRing: $0.keyRing.publicKeyRing, isHidden: false)  }
//                encryptor = try DMSPGPEncryptor(publicKeyDataList: publicKeyDataList)
//            }
//
//            let encrypted = try encryptor.encrypt(message: message)
//            return encrypted
        } catch {
            throw TCError.composeError(reason: .pgpError(error))
        }

    }

}
