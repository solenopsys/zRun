function ComponentBase(props) {
    this.props = props;
}
ComponentBase.prototype.setState = function(state) {
    this.state = state;
};
var instance = new ComponentBase({name: "zRun"});
instance.setState({ready: true});
var nullishKeys = 0;
for (var key in null) nullishKeys++;
for (var missingKey in undefined) nullishKeys++;
if (ComponentBase.prototype.constructor === ComponentBase &&
    instance.props.name == "zRun" && instance.state.ready &&
    typeof ComponentBase.prototype.setState == "function" &&
    Math.random().toString(8).length > 2 && nullishKeys == 0) {
    print("PASS function prototype construction and dispatch");
} else {
    print("FAIL function prototype construction and dispatch");
}
