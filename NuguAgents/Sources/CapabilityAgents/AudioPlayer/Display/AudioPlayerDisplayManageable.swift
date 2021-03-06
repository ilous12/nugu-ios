//
//  AudioPlayerDisplayManageable.swift
//  NuguAgents
//
//  Created by MinChul Lee on 2019/07/17.
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

/// The `AudioPlayerAgent` handles directives for controlling player template display.
protocol AudioPlayerDisplayManageable {
    /// Sets a delegate to be notified of `AudioPlayerDisplayTemplate` changes.
    var delegate: AudioPlayerDisplayDelegate? { get set }
    
    func display(payload: AudioPlayerAgentMedia.Payload, messageId: String, dialogRequestId: String)
    
    func updateMetadata(payload: Data, playServiceId: String)
    
    func showLyrics(playServiceId: String, completion: @escaping (Bool) -> Void)
    
    func hideLyrics(playServiceId: String, completion: @escaping (Bool) -> Void)
    
    func isLyricsVisible(playServiceId: String, completion: @escaping (Bool) -> Void)
    
    func controlLyricsPage(payload: AudioPlayerDisplayControlPayload, completion: @escaping (Bool) -> Void)
    
    /// This should be called when occur interaction(input event such as touch, drag, etc...) for display
    func notifyUserInteraction()
}
