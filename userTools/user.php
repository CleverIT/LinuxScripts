#!/usr/bin/php
<?php

error_reporting(E_ALL);
ini_set('display_errors', 'on');

// Bepaal user parameters
$action = null;
$configFile = 'user.config.php';
$removeDirs = false;
$username = null;
$options = getopt('', array('action:', 'configFile::', 'removeDirs', 'username:'));
foreach ($options as $name => $value) {
        switch ($name) {
                case 'action':
                        $action = $value;
                        break;
                case 'configFile':
                        $configFile = $value;
                        break;
                case 'removeDirs':
                        $removeDirs = true;
                        break;
                case 'username':
                        $username = $value;
                        break;
        }
}
if (!$action || !$username) {
        echo 'Usage:' . "\n\n";
        echo "\t" . 'user --action=add --username=... [--configFile=user.config.php]' . "\n";
        echo "\t" . 'user --action=resetpw --username=... [--configFile=user.config.php]' . "\n";
        echo "\t" . 'user --action=remove [--removeDirs] --username=... [--configFile=user.config.php]' . "\n\n";
        exit(1);
}

// Include de user config
require_once($configFile);

// Bepaal directories
$homedir = sprintf($config['userDir'], $username);
$vhostDir = sprintf($config['vhostDir'], $username);

// Voer actie uit
$userInfo = posix_getpwnam($username);
$db = mysql_connect('localhost', $config['mysqlUsername'], $config['mysqlPassword']);
if ($action == 'add') {
        if ($userInfo) {
                throw new Exception('User with that name already exists');
        }
        $cmdUserAdd = 'useradd --create-home --shell /bin/bash ' . $username . ' --home-dir ' . $homedir;
        if ($config['defaultGroups']) {
            $cmdUserAdd .= ' --groups ' . implode(',', $config['defaultGroups']);
        }
        shell_exec($cmdUserAdd);
        shell_exec('usermod --groups ' . $username . ' --append www-data');
        shell_exec('chmod o-rx ' . $homedir);

        $password = randomPass();
        file_put_contents('pass.txt', $username . ':' . $password);
        shell_exec('chpasswd < pass.txt');
        unlink('pass.txt');

        shell_exec('mkdir -p ' . $vhostDir . 'default');
        shell_exec('mkdir -p ' . $vhostDir . 'sessions');
        shell_exec('mkdir -p ' . $vhostDir . 'uploadtmp');
        shell_exec('chown ' . $username . ':' . $username . ' -R ' . $vhostDir);
        shell_exec('chmod 750 ' . $vhostDir);

        mysql_query('CREATE USER \'' . $username . '\'@\'%\' IDENTIFIED BY \'' . mysql_real_escape_string($password) . '\'');
        mysql_query('GRANT ALL PRIVILEGES ON `' . $username . '_%`.* TO \'' . $username . '\'@\'%\'');

        echo 'User created:' . "\n\n";
        echo "\t" . 'Username: ' . $username . "\n";
        echo "\t" . 'Password: ' . $password . "\n";
} else if ($action == 'resetpw') {
        $password = randomPass();
        file_put_contents('pass.txt', $username . ':' . $password);
        shell_exec('chpasswd < pass.txt');
        unlink('pass.txt');

        mysql_query('SET PASSWORD FOR \'' . $username . '\'@\'%\' = PASSWORD(\'' . mysql_real_escape_string($password) . '\')');

        echo 'Password reset:' . "\n\n";
        echo "\t" . 'Username: ' . $username . "\n";
        echo "\t" . 'Password: ' . $password . "\n";
} else if ($action == 'remove') {
        if (!$userInfo) {
                throw new Exception('User with that name does not exist');
        }
        mysql_query('DROP USER \'' . $username . '\'@\'%\'');
        if ($removeDirs) {
                shell_exec('rm -rf ' . $vhostDir);
                shell_exec('rm -rf ' . $homedir);
        }
        shell_exec('userdel ' . $username);
} else {
        throw new Exception('Invalid action: ' . $action);
}
mysql_close($db);

function randomPass() {
        $length = mt_rand(7, 12);
        $characters = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ01213456789.!/$#';
        $pass = '';
        for ($i = 0; $i < $length; ++$i) {
                $pass .= $characters[mt_rand(0, strlen($characters) - 1)];
        }
        return $pass;
}
