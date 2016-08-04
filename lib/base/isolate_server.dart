part of aqueduct;

class _Server {
  ApplicationInstanceConfiguration configuration;
  HttpServer server;
  ApplicationPipeline pipeline;
  int identifier;
  Logger get logger => new Logger("aqueduct");

  _Server(this.pipeline, this.configuration, this.identifier) {
    pipeline.server = this;
  }

  Future start() async {
    try {
      pipeline.addRoutes();
      pipeline.router?.finalize();
      pipeline.nextHandler = pipeline.initialHandler();

      if (configuration.securityContext != null) {
        server = await HttpServer.bindSecure(configuration.address, configuration.port, configuration.securityContext,
            requestClientCertificate: configuration.isUsingClientCertificate,
            v6Only: configuration.isIpv6Only,
            shared: configuration._shared);
      } else {
        server = await HttpServer.bind(configuration.address, configuration.port,
            v6Only: configuration.isIpv6Only,
            shared: configuration._shared);
      }

      server.autoCompress = true;
      await didOpen();
    } catch (e) {
      await server?.close(force: true);
      rethrow;
    }
  }

  Future didOpen() async {
    logger.info("Server aqueduct/$identifier started.");

    server.serverHeader = "aqueduct/${this.identifier}";

    await pipeline.willOpen();

    server.map((baseReq) => new Request(baseReq)).listen((Request req) async {
      logger.fine("Request received $req.", req);
      await pipeline.willReceiveRequest(req);
      pipeline.deliver(req);
    });

    pipeline.didOpen();
  }
}

class IsolateServer extends _Server {
  SendPort supervisingApplicationPort;
  ReceivePort supervisingReceivePort;

  IsolateServer(ApplicationPipeline pipeline, ApplicationInstanceConfiguration configuration, int identifier, this.supervisingApplicationPort)
    : super(pipeline, configuration, identifier) {
    pipeline.server = this;
    supervisingReceivePort = new ReceivePort();
    supervisingReceivePort.listen(listener);
  }

  @override
  Future didOpen() async {
    await super.didOpen();

    supervisingApplicationPort.send(supervisingReceivePort.sendPort);
  }

  void listener(dynamic message) {
    if (message == IsolateSupervisor._MessageStop) {
      server.close(force: true).then((s) {
        supervisingApplicationPort.send(IsolateSupervisor._MessageStop);
      });
    }
  }
}

void isolateServerEntryPoint(InitialServerMessage params) {
  var pipelineSourceLibraryMirror = currentMirrorSystem().libraries[params.pipelineLibraryURI];
  var pipelineTypeMirror = pipelineSourceLibraryMirror.declarations[new Symbol(params.pipelineTypeName)] as ClassMirror;

  var app = pipelineTypeMirror
      .newInstance(new Symbol(""), [params.configuration.pipelineOptions])
      .reflectee;
  var server = new IsolateServer(
      app, params.configuration, params.identifier,
      params.parentMessagePort);

  server.start();
}