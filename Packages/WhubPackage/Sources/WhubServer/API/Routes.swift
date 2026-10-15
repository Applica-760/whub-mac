import Hummingbird

func makeRouter(files: FilesAPI) -> Router<BasicRequestContext> {
    let router = Router()
    router.get("ping") { _, _ -> String in "pong" }
    router.get("files/list") { request, _ -> Response in
        await files.list(query: request.uri.query)
    }
    router.get("files/read") { request, _ -> Response in
        await files.readText(query: request.uri.query)
    }
    return router
}
