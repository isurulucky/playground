import ballerina/http;
import ballerina/system;
import ballerina/log;
import playground_commons as commons;
import ballerinax/java;

final string RESPONSE_HANDLER = "RESPONSE_HANDLER";
final string POST_COMPILE_CALLBACK = "POST_COMPILE_CALLBACK";

function invokeExecutor(ResponseHandler respHandler, RunData data) returns error? {
    string executorHost = system:getEnv("EXECUTOR_HOST");
    log:printDebug("executor-proxy:selectedHost: " + executorHost);

    service Callback = @http:WebSocketServiceConfig {} service {
        resource function onText(http:WebSocketClient conn, string text, boolean finalFrame) {
            log:printDebug("executor-proxy:OnText:  \n" + text + "\n");
            log:printDebug("compiler-proxy: Invoke reponse handler.");
            var respHandler = conn.getAttribute(RESPONSE_HANDLER);
            if (respHandler is ResponseHandler) {
                respHandler(text, true);
            } else {
                log:printError("Cannot find respond handler reference.");
            }
        }
        resource function onError(http:WebSocketClient conn, error err) {
            log:printError("executor-proxy:OnError: " + err.reason());

            var respHandler = <ResponseHandler> conn.getAttribute(RESPONSE_HANDLER);
            respHandler(createErrorResponse("Error while executing. " + err.reason()), true);
        }
    };

    http:WebSocketClient executorClient = new(executorHost,
                            config = {callbackService: Callback});
    executorClient.setAttribute(RESPONSE_HANDLER, respHandler);

    // initiate execution
    json executeRequest = {
        'type: "Execute",
        'data: check json.constructFrom(data)
    };
    log:printDebug("executor-proxy:execute: " + executeRequest.toJsonString());
    check executorClient->pushText(executeRequest);
}

function hasCompilationEndedSuccessfully(string msg) returns [boolean,boolean]|error {
    PlaygroundResponse resp = check PlaygroundResponse.constructFrom(check msg.fromJsonString());       
    if (resp.'type is ControlResponse) {
        if (resp.data == "Finished Compiling with errors.") {
            return [true, false];
        }
        if (resp.data === "Finished Compiling.") {
            return [true, true];
        }
    }
    return [false, false];
}

function invokeCompiler(ResponseHandler respHandler, RunData data, 
                CompilerCompletionCallback onCompletion) returns error? {
    string compilerHost = system:getEnv("COMPILER_HOST");
    log:printDebug("compiler-proxy:selectedHost: " + compilerHost);

    service Callback = @http:WebSocketServiceConfig {} service {
        resource function onText(http:WebSocketClient conn, string text, boolean finalFrame) {
            log:printDebug("compiler-proxy:OnText: \n" + text + "\n");
            log:printDebug("compiler-proxy: Invoke reponse handler.");
            var respHandler = conn.getAttribute(RESPONSE_HANDLER);
            if (respHandler is ResponseHandler) {
                respHandler(text, true);
            } else {
                log:printError("Cannot find respond handler reference.");
            }
           
            // check whether the compilation was successful
            [boolean,boolean]|error compilationStatus = hasCompilationEndedSuccessfully(text);
            if (compilationStatus is error) {
                log:printError("Error while detecting compilation status. ", compilationStatus);
            } else if (compilationStatus == [true, true]) {
                CompilerCompletionCallback onCompletion = 
                    <CompilerCompletionCallback> conn.getAttribute(POST_COMPILE_CALLBACK);
                onCompletion(true);
            } else if (compilationStatus == [true, false]) {
                CompilerCompletionCallback onCompletion = 
                    <CompilerCompletionCallback> conn.getAttribute(POST_COMPILE_CALLBACK);
                onCompletion(false);
            }
        }
        resource function onError(http:WebSocketClient conn, error err) {
            log:printError("compiler-proxy:OnError: " + err.reason());

            var respHandler = <ResponseHandler> conn.getAttribute(RESPONSE_HANDLER);
            respHandler(createErrorResponse("Error while compiling. " + err.reason()), true);

            CompilerCompletionCallback onCompletion = 
                <CompilerCompletionCallback> conn.getAttribute(POST_COMPILE_CALLBACK);
            onCompletion(false);
        }
    };

    http:WebSocketClient compilerClient = new(compilerHost,
                            config = {callbackService: Callback});
    compilerClient.setAttribute(RESPONSE_HANDLER, respHandler);
    compilerClient.setAttribute(POST_COMPILE_CALLBACK, onCompletion);

    // initiate compilation
    json compileRequest = {
        'type: "Compile",
        'data: check json.constructFrom(data)
    };
    log:printDebug("compiler-proxy:compile: " + compileRequest.toJsonString());
    check compilerClient->pushText(compileRequest);
}

function run(http:WebSocketCaller caller, RunData data) returns error? {
    string cacheId = commons:getCacheId(data.sourceCode, data.balVersion);
    log:printDebug("Cache ID for Request : " + cacheId);

    ResponseHandler respHandler = function(PlaygroundResponse|string resp, boolean cache) {
        log:printDebug("Responding to frontend: \n" + resp.toString() + "\n");
        string stringResponse = "";
        if (resp is PlaygroundResponse) {
            json|error jsonResponse = createJSONResponse(resp);
            if (jsonResponse is error) {
                log:printError("Error while creating json response. " + jsonResponse.reason());
            } else {
                stringResponse = jsonResponse.toString();
            }
        } else {
            stringResponse = resp;
        }
        
        error? respondStatus = caller->pushText(stringResponse);
        if (respondStatus is error) {
            log:printError("Error while responding. " + respondStatus.reason());
        }
        if (cache) {
            commons:redisPushToList(java:fromString(cacheId), java:fromString(stringResponse));
        } 
    };

    CompilerCompletionCallback compilerCallBack = function(boolean isSuccess) {
        if (isSuccess) {
            error? executorResult = invokeExecutor(respHandler, data);
            if (executorResult is error) {
                log:printError("Error with executor. " + executorResult.reason());
            }
        }
    };
    [boolean, boolean, string[]] checkCacheResult = checkCache(cacheId);
    if (checkCacheResult[0] && checkCacheResult[1]) {
        log:printDebug("Found valid cached responses. ");
        foreach string response in checkCacheResult[2] {
            respHandler(response, false);
        }
    } else {
        // invalidate cache entry if it exists & invalid
        if (checkCacheResult[0] && !checkCacheResult[1]) {
            commons:redisRemove(java:fromString(cacheId));
        }
        log:printDebug("Cached responses not found. Compiling. ");
        error? compilerResult = invokeCompiler(respHandler, data, compilerCallBack);
        if (compilerResult is error) {
            log:printError("Error with compiler. " + compilerResult.reason());
        }
    }
}


# Check if a valid cache exists and return cache if it exists.
#
# + cacheId - cacheId Parameter 
# + return - [isCacheAvailable, isCacheValid, cache]
function checkCache(string cacheId) returns [boolean, boolean, string[]] {
    if (commons:redisContains(java:fromString(cacheId))) {
        string[] cachedResponses = commons:redisGetList(cacheId);
        string lastResponse = cachedResponses[cachedResponses.length() - 1];
        json|error jsonResponse = lastResponse.fromJsonString();
        if (jsonResponse is json) {
            PlaygroundResponse|error response = PlaygroundResponse.constructFrom(jsonResponse);
            if (response is PlaygroundResponse) {
                boolean isValid = response.'type == ControlResponse && 
                    (response.data == "Finished Executing."
                        || response.data == "Finished Compiling with errors.");
                return [true, isValid, cachedResponses];
            }
        }
        return [true, false, cachedResponses];
    }
    return [false, false, []];
}

function createJSONResponse(PlaygroundResponse reponse) returns json|error {
    json jsonResp = check json.constructFrom(reponse);
    return jsonResp.toJsonString();
}

function createDataResponse(string data) returns PlaygroundResponse {
    return <PlaygroundResponse> { "type": DataResponse, "data": data };
}

function createErrorResponse(string data) returns PlaygroundResponse {
    return <PlaygroundResponse> { "type": ErrorResponse, "data": data };
}