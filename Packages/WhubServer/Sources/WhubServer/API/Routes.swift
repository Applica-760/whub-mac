import Hummingbird

func makeRouter(files: FilesAPI) -> Router<BasicRequestContext> {
    let router = Router()
    router.get("ping") { _, _ -> String in "pong" }
    router.get("files") { request, _ -> Response in
        await files.list(query: request.uri.query)
    }
    return router
}
