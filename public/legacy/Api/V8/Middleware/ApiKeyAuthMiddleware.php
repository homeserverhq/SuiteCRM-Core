<?php

namespace Api\V8\Middleware;

use Api\V8\BeanDecorator\BeanManager;
use League\OAuth2\Server\Exception\OAuthServerException;
use League\OAuth2\Server\ResourceServer;
use Psr\Http\Message\ResponseInterface;
use Psr\Http\Message\ServerRequestInterface;
use Slim\Http\Response;

class ApiKeyAuthMiddleware
{
    private ResourceServer $resourceServer;
    private BeanManager $beanManager;

    public function __construct(ResourceServer $resourceServer, BeanManager $beanManager)
    {
        $this->resourceServer = $resourceServer;
        $this->beanManager = $beanManager;
    }

    public function __invoke(ServerRequestInterface $request, ResponseInterface $response, callable $next): ResponseInterface
    {
        $authHeader = $request->getHeaderLine('Authorization');

        if (strpos($authHeader, 'Bearer ') === 0) {
            $token = substr($authHeader, 7);

            if (!empty($token)) {
                $user = $this->findUserByApiKey($token);
                if ($user !== null) {
                    $GLOBALS['current_user'] = $user;
                    $request = $request->withAttribute('oauth_user_id', $user->id);
                    return $next($request, $response);
                }
            }
        }

        try {
            $request = $this->resourceServer->validateAuthenticatedRequest($request);
            return $next($request, $response);
        } catch (OAuthServerException $e) {
            return $e->generateHttpResponse($response);
        } catch (\Exception $e) {
            $response = $response->withStatus(401);
            $response->getBody()->write(json_encode(['error' => 'invalid_token']));
            return $response->withHeader('Content-Type', 'application/json');
        }
    }

    private function findUserByApiKey(string $apiKey): ?\User
    {
        if (empty($apiKey)) {
            return null;
        }

        if (!isset($GLOBALS['db']) || $GLOBALS['db'] === null) {
            return null;
        }

        $db = $GLOBALS['db'];
        $query = "SELECT id, api_key FROM users WHERE api_key = '" . $db->quote($apiKey) . "' AND status = 'Active' AND deleted = 0 LIMIT 1";
        $result = $db->query($query, false, 'API key lookup failed');

        if ($result === false || $result === true) {
            return null;
        }

        $row = $db->fetchByAssoc($result);
        if (empty($row) || empty($row['id'])) {
            return null;
        }

        $user = \BeanFactory::getBean('Users', $row['id']);
        if ($user === false || empty($user->id)) {
            return null;
        }

        return $user;
    }
}
