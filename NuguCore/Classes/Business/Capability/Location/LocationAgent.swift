//
//  LocationAgent.swift
//  NuguCore
//
//  Created by yonghoonKwon on 2019/10/31.
//  Copyright (c) 2019 SK Telecom Co., Ltd. All rights reserved.
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

import NuguInterface

final public class LocationAgent: LocationAgentProtocol {
    public var capabilityAgentProperty: CapabilityAgentProperty = CapabilityAgentProperty(category: .location, version: "1.0")
    
    public weak var delegate: LocationAgentDelegate?
    
    public init() {
        log.info("")
    }
    
    deinit {
        log.info("")
    }
}

// MARK: - ProvideContextDelegate

extension LocationAgent: ProvideContextDelegate {
    public func provideContext() -> ContextInfo? {
        var payload: [String: Any?] = [
            "version": capabilityAgentProperty.version
        ]
        
        if let locationInfo = delegate?.locationAgentRequestLocation() {
            payload["current"] = [
                "latitude": locationInfo.latitude,
                "longitude": locationInfo.longitude
            ]
        }
        
        return ContextInfo(
            contextType: .capability,
            name: capabilityAgentProperty.name,
            payload: payload.compactMapValues { $0 }
        )
    }
}