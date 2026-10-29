import Hummingbird

func makeRouter(files: FilesAPI, manager: ManagerAPI, agent: AgentAPI, git: GitAPI = GitAPI()) -> Router<BasicRequestContext> {
    let router = Router()
    router.get("ping") { _, _ -> String in "pong" }

	// Git API
    router.post("git/watches") { request, _ -> Response in
        await git.startWatch(query: request.uri.query)
    }
    router.get("git/watches/:id") { request, context -> Response in
        try await git.waitWatch(id: context.parameters.get("id") ?? "", query: request.uri.query)
    }
    router.delete("git/watches/:id") { _, context -> Response in
        await git.stopWatch(id: context.parameters.get("id") ?? "")
    }
    router.get("git/changes") { request, _ -> Response in
        await git.changes(query: request.uri.query)
    }
    router.get("git/diff") { request, _ -> Response in
        await git.diff(query: request.uri.query)
    }

    // Files API
    router.get("files/list") { request, _ -> Response in
        await files.list(query: request.uri.query)
    }
    router.get("files/read") { request, _ -> Response in
        await files.readText(query: request.uri.query)
    }
    router.get("files/read-image") { request, _ -> Response in
        await files.readImage(query: request.uri.query)
    }
    router.put("files/write") { request, _ -> Response in
        await files.writeText(request)
    }
    router.post("files/create-file") { request, _ -> Response in
        await files.operate(request, operation: .createFile)
    }
    router.post("files/create-directory") { request, _ -> Response in
        await files.operate(request, operation: .createDirectory)
    }
    router.post("files/rename") { request, _ -> Response in
        await files.operate(request, operation: .rename)
    }
    router.post("files/trash") { request, _ -> Response in
        await files.operate(request, operation: .trash)
    }

    // Manager API
    router.post("manager/updates") { request, _ in await manager.handle(request, action: .start(.update)) }
    router.post("manager/fetch") { request, _ in await manager.handle(request, action: .start(.fetch)) }
    router.get("manager/commits") { request, _ in await manager.handle(request, action: .commits) }
    router.post("manager/builds") { request, _ in await manager.handle(request, action: .start(.build)) }
    router.get("manager/builds") { request, _ in await manager.handle(request, action: .builds) }
    router.post("manager/apply") { request, _ in await manager.handle(request, action: .start(.apply)) }
    router.post("manager/restart") { request, _ in await manager.handle(request, action: .start(.restart)) }
    router.get("manager/updates") { request, _ in await manager.handle(request, action: .history) }
    router.get("manager/updates/:id") { request, context in
        await manager.handle(request, action: .update(context.parameters.get("id") ?? ""))
    }
    router.get("manager/updates/:id/log") { request, context in
        await manager.handle(request, action: .log(context.parameters.get("id") ?? ""))
    }
    router.get("manager/status") { request, _ in await manager.handle(request, action: .status) }

    // Agent API
    router.post("agent/sessions") { request, _ in try await agent.handle(request, action: .create) }
    router.get("agent/sessions") { request, _ in try await agent.handle(request, action: .list) }
    router.get("agent/sessions/:id") { request, context in
        try await agent.handle(request, action: .state(context.parameters.get("id") ?? ""))
    }
    router.delete("agent/sessions/:id") { request, context in
        try await agent.handle(request, action: .close(context.parameters.get("id") ?? ""))
    }
    router.get("agent/sessions/:id/changes") { request, context in
        try await agent.handle(request, action: .changes(context.parameters.get("id") ?? ""))
    }
    router.post("agent/sessions/:id/snapshots") { request, context in
        try await agent.handle(request, action: .openSnapshot(context.parameters.get("id") ?? ""))
    }
    router.get("agent/sessions/:id/snapshots/:snapshot") { request, context in
        try await agent.handle(request, action: .snapshot(context.parameters.get("id") ?? "", context.parameters.get("snapshot") ?? ""))
    }
    router.delete("agent/sessions/:id/snapshots/:snapshot") { request, context in
        try await agent.handle(request, action: .releaseSnapshot(context.parameters.get("id") ?? "", context.parameters.get("snapshot") ?? ""))
    }
    router.get("agent/sessions/:id/images/:image") { request, context in
        try await agent.handle(request, action: .image(context.parameters.get("id") ?? "", context.parameters.get("image") ?? ""))
    }
    router.post("agent/sessions/:id/commands") { request, context in
        try await agent.handle(request, action: .execute(context.parameters.get("id") ?? ""))
    }
    router.get("agent/sessions/:id/models") { request, context in
        try await agent.handle(request, action: .models(context.parameters.get("id") ?? ""))
    }
    router.get("agent/sessions/:id/skills") { request, context in
        try await agent.handle(request, action: .skills(context.parameters.get("id") ?? ""))
    }
    router.get("agent/sessions/:id/status") { request, context in
        try await agent.handle(request, action: .status(context.parameters.get("id") ?? ""))
    }
    router.get("agent/sessions/:id/history") { request, context in
        try await agent.handle(request, action: .history(context.parameters.get("id") ?? ""))
    }

    return router
}
