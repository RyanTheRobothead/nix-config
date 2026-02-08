{
  lib,
  python3Packages,
  fetchPypi,
}:

python3Packages.buildPythonApplication rec {
  pname = "argo-proxy";
  version = "2.8.3";
  pyproject = true;

  src = fetchPypi {
    pname = "argo_proxy";
    inherit version;
    hash = "sha256-6b3QBoDmy7YdnZs+Oq2GGJaaR2DPY72dbg2vxqjfthQ=";
  };

  build-system = [ python3Packages.setuptools ];

  dependencies = with python3Packages; [
    aiohttp
    loguru
    pyyaml
    pydantic
    tiktoken
    tqdm
    packaging
    pillow
  ];

  pythonImportsCheck = [ "argoproxy" ];

  meta = {
    description = "Proxy server for ARGO API with OpenAI compatibility";
    homepage = "https://github.com/Oaklight/argo-proxy";
    license = lib.licenses.mit;
    mainProgram = "argo-proxy";
  };
}
