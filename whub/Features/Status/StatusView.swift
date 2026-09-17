//
//  StatusView.swift
//  whub
//
//  Created by 村上匠 on 2026/09/10.
//

import SwiftUI

private struct Status: Identifiable {
    var id: String { project }

    let project: String
    let state: String
    let type: String
}

struct StatusView: View {
    var body: some View {
        StatusWidget()
            .padding()
            .navigationTitle("Status")
    }
}

struct StatusWidget: View {
    private let resources = [
        Status(project: "whub-dev", state: "ok", type: "symlink"),
        Status(project: "vault", state: "ok", type: "symlink"),
        Status(project: "la-il", state: "slow", type: "remote"),
    ]

    var body: some View {
        WidgetFrame {
            Table(resources) {
                TableColumn("Project", value: \.project)
                TableColumn("State", value: \.state)
                TableColumn("Type", value: \.type)
            }
        }
    }
}
