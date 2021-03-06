//
//  PhoneCallAgent.swift
//  NuguAgents
//
//  Created by yonghoonKwon on 2020/04/29.
//  Copyright (c) 2020 SK Telecom Co., Ltd. All rights reserved.
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

import Foundation

import NuguCore

public class PhoneCallAgent: PhoneCallAgentProtocol {
    public var capabilityAgentProperty: CapabilityAgentProperty = CapabilityAgentProperty(category: .phoneCall, version: "1.1")
    
    // PhoneCallAgentProtocol
    public weak var delegate: PhoneCallAgentDelegate?
    
    // private
    private let directiveSequencer: DirectiveSequenceable
    private let contextManager: ContextManageable
    private let upstreamDataSender: UpstreamDataSendable
    private let interactionControlManager: InteractionControlManageable
    
    private let phoneCallDispatchQueue = DispatchQueue(label: "com.sktelecom.romaine.phonecall_agent", qos: .userInitiated)
    
    // Current directive info
    private var currentMakeCallMessageId: String?
    
    // Handleable Directive
    private lazy var handleableDirectiveInfos: [DirectiveHandleInfo] = [
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "SendCandidates", blockingPolicy: BlockingPolicy(medium: .none, isBlocking: false), directiveHandler: handleSendCandidates),
        DirectiveHandleInfo(namespace: capabilityAgentProperty.name, name: "MakeCall", blockingPolicy: BlockingPolicy(medium: .audio, isBlocking: false), preFetch: prefetchMakeCall, directiveHandler: handleMakeCall)
    ]
    
    public init(
        directiveSequencer: DirectiveSequenceable,
        contextManager: ContextManageable,
        upstreamDataSender: UpstreamDataSendable,
        interactionControlManager: InteractionControlManageable
    ) {
        self.directiveSequencer = directiveSequencer
        self.contextManager = contextManager
        self.upstreamDataSender = upstreamDataSender
        self.interactionControlManager = interactionControlManager
        
        contextManager.add(delegate: self)
        directiveSequencer.add(directiveHandleInfos: handleableDirectiveInfos.asDictionary)
    }
}

// MARK: - PhoneCallAgentProtocol

public extension PhoneCallAgent {
    @discardableResult func requestSendCandidates(playServiceId: String, completion: ((StreamDataState) -> Void)?) -> String {
        let eventIdentifier = EventIdentifier()
        self.contextManager.getContexts { [weak self] (contextPayload) in
            guard let self = self else { return }
            self.upstreamDataSender.sendEvent(
                Event(
                    playServiceId: playServiceId,
                    typeInfo: .candidatesListed
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    contextPayload: contextPayload
                )
            ) { [weak self] state in
                completion?(state)
                guard let self = self else { return }
                switch state {
                case .finished, .error:
                    self.interactionControlManager.finish(mode: .multiTurn, category: self.capabilityAgentProperty.category)
                default:
                    break
                }
            }
        }
        
        return eventIdentifier.dialogRequestId
    }
}

// MARK: - ContextInfoDelegate

extension PhoneCallAgent: ContextInfoDelegate {
    public func contextInfoRequestContext(completion: @escaping (ContextInfo?) -> Void) {
        let state = delegate?.phoneCallAgentRequestState()
        let template = delegate?.phoneCallAgentRequestTemplate()
        
        var payload: [String: AnyHashable?] = [
            "version": capabilityAgentProperty.version,
            "state": state?.rawValue ?? PhoneCallState.idle.rawValue
        ]
        
        if let templateItem = template,
            let templateData = try? JSONEncoder().encode(templateItem),
            let templateDictionary = try? JSONSerialization.jsonObject(with: templateData, options: []) as? [String: AnyHashable] {
            payload["template"] = templateDictionary
        }
        
        completion(
            ContextInfo(
                contextType: .capability,
                name: capabilityAgentProperty.name,
                payload: payload.compactMapValues { $0 }
            )
        )
    }
}

// MARK: - Private(Directive)

private extension PhoneCallAgent {
    func handleSendCandidates() -> HandleDirective {
        return { [weak self] directive, completion in
            
            guard let self = self else {
                completion(.canceled)
                return
            }
            
            self.phoneCallDispatchQueue.async { [weak self] in
                guard let self = self, let delegate = self.delegate else {
                    completion(.canceled)
                    return
                }
                
                guard let payloadDictionary = directive.payloadDictionary else {
                    completion(.failed("Invalid payload"))
                    return
                }
                guard let payloadData = try? JSONSerialization.data(withJSONObject: payloadDictionary, options: []),
                    let candidatesItem = try? JSONDecoder().decode(PhoneCallCandidatesItem.self, from: payloadData) else {
                        completion(.failed("Invalid candidateItem in payload"))
                        return
                }
                
                defer { completion(.finished) }
                
                // TODO: Check interaction mode in payload.
                self.interactionControlManager.start(mode: .multiTurn, category: self.capabilityAgentProperty.category)
                delegate.phoneCallAgentDidReceiveSendCandidates(
                    item: candidatesItem,
                    dialogRequestId: directive.header.dialogRequestId
                )
            }
        }
    }
    
    func prefetchMakeCall() -> PrefetchDirective {
        return { [weak self] directive in
            self?.phoneCallDispatchQueue.sync { [weak self] in
                self?.currentMakeCallMessageId = directive.header.messageId
            }
        }
    }
    
    func handleMakeCall() -> HandleDirective {
        return { [weak self] directive, completion in
            guard let self = self else {
                completion(.canceled)
                return
            }
            
            self.phoneCallDispatchQueue.async { [weak self] in
                guard let self = self else {
                    completion(.canceled)
                    return
                }
                
                guard self.currentMakeCallMessageId == directive.header.messageId else {
                    completion(.canceled)
                    log.info("Message id does not match")
                    return
                }
                
                guard let payloadDictionary = directive.payloadDictionary else {
                    completion(.failed("Invalid payload"))
                    return
                }
                
                guard let playServiceId = payloadDictionary["playServiceId"] as? String,
                    let callType = payloadDictionary["callType"] as? String,
                    let phoneCallType = PhoneCallType(rawValue: callType) else {
                        completion(.failed("Invalid callType or playServiceId in payload"))
                        return
                }
                
                guard let recipientDictionary = payloadDictionary["recipient"] as? [String: AnyHashable],
                    let recipientData = try? JSONSerialization.data(withJSONObject: recipientDictionary, options: []),
                    let recipientPerson = try? JSONDecoder().decode(PhoneCallPerson.self, from: recipientData) else {
                        completion(.failed("Invalid recipient in payload"))
                        return
                }
                
                defer { completion(.finished) }

                if let errorCode = self.delegate?.phoneCallAgentDidReceiveMakeCall(
                    callType: phoneCallType,
                    recipient: recipientPerson,
                    dialogRequestId: directive.header.dialogRequestId
                    ) {
                    self.sendMakeCallFailed(playServiceId: playServiceId, errorCode: errorCode, phoneCallType: phoneCallType)
                }
            }
        }
    }
}

// MARK: - Private (Event)

private extension PhoneCallAgent {
    func sendMakeCallFailed(playServiceId: String, errorCode: PhoneCallErrorCode, phoneCallType: PhoneCallType) {
        let eventIdentifier = EventIdentifier()
        self.contextManager.getContexts(namespace: self.capabilityAgentProperty.name) { [weak self] contextPayload in
            guard let self = self else { return }
            
            self.upstreamDataSender.sendEvent(
                Event(
                    playServiceId: playServiceId,
                    typeInfo: .makeCallFailed(errorCode: errorCode, callType: phoneCallType)
                ).makeEventMessage(
                    property: self.capabilityAgentProperty,
                    eventIdentifier: eventIdentifier,
                    contextPayload: contextPayload
                )
            )
        }
    }
}
