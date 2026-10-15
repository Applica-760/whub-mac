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
    router.post("manager/updates") { request, _ in await manager.handle(request, action: .start) }
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
