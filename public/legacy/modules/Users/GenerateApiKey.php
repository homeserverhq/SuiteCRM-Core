<?php

if (!defined('sugarEntry') || !sugarEntry) {
    die('Not A Valid Entry Point');
}

require_once __DIR__ . '/../../include/entryPoint.php';

$key = '';
$chars = '0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ';
for ($i = 0; $i < 32; $i++) {
    $key .= $chars[random_int(0, strlen($chars) - 1)];
}

if (!empty($GLOBALS['current_user']) && !empty($GLOBALS['current_user']->id)) {
    $db = \DBManagerFactory::getInstance();
    $userId = $GLOBALS['current_user']->id;
    $quotedKey = $db->quote($key);
    $db->query("UPDATE users SET api_key='$quotedKey' WHERE id='$userId'");
}

while (ob_get_level() > 0) {
    ob_end_clean();
}

header('Content-Type: application/json');
echo json_encode(['api_key' => $key]);
exit;
