<?php

/* Configuratie voor generate.php */

$SSLDir = '/etc/apache2/certificates/';
$genericSSLKey = $SSLDir . 'serverXX.key';
$genericSSLCert = $SSLDir . 'serverXX.crt';

$vhostsPath = '/home/%1$s/vhosts';
$websitePath = '/home/%1$s/vhosts/%2$s';

$apacheVhostDir = '/etc/apache2/sites-available/';
$vhostFile = 'vhost-users.conf';
$FPMPoolsFile = '/etc/php5/fpm/pool.d/users.conf';
$FPMMaxChildren = 8;

$vhosts = [
    'username' => [
        //'allow' => '192.168.0.0/24'.
        //'defaultIP' => '95.170.75.8',
        'vhosts' => [
            'vhost-domain.nl' => ['target' => 'vhost-dirname', 'port' => 80],
            //'vhost-extended.nl' => [
            //  'target' => 'vhost-dirname2',
            //  'IP' => '127.0.0.1',
            //  'ports' => [80, 443],
            //  'aliases' => ['www.ietsanders.nl', 'iets.anders.nl'],
            //  'allow' => '192.168.0.0/16',
            //  'sslCert' => '/path/to/ssl.crt',
            //  'sslKey' => '/path/to/ssl.key',
            //  'customConfig' => [
            //      'RewriteEngine On',
            //      'RewriteRule ...',
            //  ],
            //],
        ],
    ],
];
