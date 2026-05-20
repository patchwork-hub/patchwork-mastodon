import { connect } from 'react-redux';

import { changeComposeFederated } from '../../../actions/compose';
import federatedDropdown from '../components/federated_dropdown';

const mapStateToProps = state => ({
  federated: state.getIn(['compose', 'federated']),
});

const mapDispatchToProps = dispatch => ({
  onChange (federated) {
    dispatch(changeComposeFederated(federated));
  },
});

export default connect(mapStateToProps, mapDispatchToProps)(federatedDropdown);
