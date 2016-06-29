Websockets and AMQP
===================

When web-socket connections establishes Cowboy creates and event-handler to handle web-socket messages. Each such
connection must be identified by unique Id to send/receive AMQP messages. Connection must be authorized either
by client providing a valid Token, or providing name/password pair. When connection is authorized no subsequent
authorization is required. Token validity must be checked on each incoming web-socket message. Access rights
must be checked on each message.

There is one gen_listener for WS-AMQP messages with one named queue "messages". Each web-socket connection adds an
AMQP binding with key "blackhole.connection.$Id", and handles incoming messages to pass them to web-socket client,
and removes the binding on web-socket connection close. Each numbered WS-AMQP message must include the binding key
to reply to.

Web-sockets messages are JSON objects. There are two types of messages: numbered (to support sync calls),
and unnumbered (to support async calls). When server replies to the numbered message it must include the same
message number into reply. Client is responsible for message numbering and matching.

Web-socket messages (incomplete list):

1. Authorize (Token or Name/Password)
2. Subscribe
3. Unsubscribe

To ease development REST API should be monomorphic to WS API, e.g. by providing handler for special WS message:

```json
    Type: REST,
    Verb: GET|POST|PUT|DELETE
    Uri: URI
    Args: Named Arguments
```