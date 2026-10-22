Connector skills — how to drive a third-party service that Alfie reaches
through a gateway rather than through a native tool. Composio is the big one:
one MCP session standing in front of ~500 toolkits, whose schemas are
authored per-tool and cannot be reasoned about as a set.

Start with `composio-router`. The per-toolkit skills below it are only for
the toolkits that CONTRADICT the router — a default that is the expensive
one, a parameter that is advertised and inert, a choice of tool that is not
obvious from the names. A toolkit that behaves the way the router describes
gets no skill, on purpose: opening one to be told "nothing unusual here"
costs a call and buys nothing.
