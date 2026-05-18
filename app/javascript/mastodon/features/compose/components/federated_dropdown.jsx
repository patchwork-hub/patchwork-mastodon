import PropTypes from 'prop-types';
import { PureComponent } from 'react';

import { injectIntl, defineMessages } from 'react-intl';

import classNames from 'classnames';

import Overlay from 'react-overlays/Overlay';

import LinkIcon from '@/material-icons/400-24px/link.svg?react';
import LinkOffIcon from '@/material-icons/400-24px/link_off.svg?react';
import { DropdownSelector } from 'mastodon/components/dropdown_selector';
import { Icon } from 'mastodon/components/icon';

const messages = defineMessages({
  federated: { id: 'compose.federated', defaultMessage: 'Federated' },
  federated_long: { id: 'compose.federated', defaultMessage: 'Allow post to reach other instances' },
  local_only: { id: 'compose.local_only_long', defaultMessage: 'Local Only' },
  local_only_long: { id: 'compose.local_only_long', defaultMessage: 'Restrict this post only to my instance' },
});

class FederatedDropdown extends PureComponent {
  static propTypes = {
    federated: PropTypes.bool.isRequired,
    onChange: PropTypes.func.isRequired,
    noDirect: PropTypes.bool,
    container: PropTypes.func,
    disabled: PropTypes.bool,
    intl: PropTypes.object.isRequired,
  };

  constructor(props) {
    super(props);

    const { intl: { formatMessage } } = props;

    this.options = [
      {
        icon: 'link',
        iconComponent: LinkIcon,
        value: 'federated',
        text: formatMessage(messages.federated),
        meta: formatMessage(messages.federated_long)
      },
      {
        icon: 'link_off',
        iconComponent: LinkOffIcon,
        value: 'local_only',
        text: formatMessage(messages.local_only),
        meta: formatMessage(messages.local_only_long)
      },
    ];

    this.state = {
      open: false,
      placement: 'bottom',
    };
  }

  handleToggle = () => {
    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    }
    this.setState({ open: !this.state.open });
  };

  handleKeyDown = (e) => {
    if (e.key === 'Escape') this.handleClose();
  };

  handleMouseDown = () => {
    if (!this.state.open) this.activeElement = document.activeElement;
  };

  handleButtonKeyDown = (e) => {
    if (e.key === ' ' || e.key === 'Enter') this.handleMouseDown();
  };

  handleClose = () => {
    if (this.state.open && this.activeElement) {
      this.activeElement.focus({ preventScroll: true });
    }
    this.setState({ open: false });
  };

   handleChange = (stringValue) => {
    const federated = stringValue === 'federated';
    this.props.onChange(federated);
  };

  setTargetRef = (c) => {
    this.target = c;
  };

  findTarget = () => this.target;

  handleOverlayEnter = (state) => {
    this.setState({ placement: state.placement });
  };

  render() {
    const { federated, container, disabled, intl } = this.props;
    const { open, placement } = this.state;

    const stringValue = federated ? 'federated' : 'local_only';
    const valueOption = this.options.find((item) => item.value === stringValue) || this.options[0];

    return (
      <div ref={this.setTargetRef} onKeyDown={this.handleKeyDown}>
        <button
          type='button'
          title={intl.formatMessage(messages.federated)}
          aria-expanded={open}
          onClick={this.handleToggle}
          onMouseDown={this.handleMouseDown}
          onKeyDown={this.handleButtonKeyDown}
          disabled={disabled}
          className={classNames('dropdown-button', { active: open })}
        >
          <Icon id={valueOption.icon} icon={valueOption.iconComponent} />
          <span className='dropdown-button__label'>{valueOption.text}</span>
        </button>

        <Overlay
          show={open}
          offset={[5, 5]}
          placement={placement}
          flip
          target={this.findTarget}
          container={container}
          popperConfig={{
            strategy: 'fixed',
            onFirstUpdate: this.handleOverlayEnter,
          }}
        >
          {({ props, placement }) => (
            <div {...props}>
              <div className={`dropdown-animation privacy-dropdown__dropdown ${placement}`}>
                <DropdownSelector
                  items={this.options}
                  value={stringValue}
                  onClose={this.handleClose}
                  onChange={this.handleChange}
                />
              </div>
            </div>
          )}
        </Overlay>
      </div>
    );
  }
}

export default injectIntl(FederatedDropdown);
