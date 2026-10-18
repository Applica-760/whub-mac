import Hummingbird

func makeRouter(files: FilesAPI, manager: ManagerAPI) -> Router<BasicRequestContext> {
    let router = Router()
    router.get("ping") { _, _ -> String in "pong" }
    router.get("files/list") { request, _ -> Response in
        await files.list(query: request.uri.query)
    }
    router.get("files/read") { request, _ -> Response in
        await files.readText(query: request.uri.query)
    }
    router.put("files/write") { request, _ -> Response in
        await files.writeText(request)
    }
    router.post("manager/updates") { request, _ in await manager.handle(request, action: .start) }
    router.post("manager/fetch") { request, _ in await manager.handle(request, action: .fetch) }
    router.get("manager/commits") { request, _ in await manager.handle(request, action: .commits) }
    router.post("manager/builds") { request, _ in await manager.handle(request, action: .build) }
    router.get("manager/builds") { request, _ in await manager.handle(request, action: .builds) }
    router.post("manager/apply") { request, _ in await manager.handle(request, action: .apply) }
    router.post("manager/restart") { request, _ in await manager.handle(request, action: .restart) }
    router.get("manager/updates") { request, _ in await manager.handle(request, action: .history) }
    router.get("manager/updates/:id") { request, context in
        await manager.handle(request, action: .update(context.parameters.get("id") ?? ""))
    }
    router.get("manager/updates/:id/log") { request, context in
        await manager.handle(request, action: .log(context.parameters.get("id") ?? ""))
    }
    router.get("manager/status") { request, _ in await manager.handle(request, action: .status) }
    return router
}
