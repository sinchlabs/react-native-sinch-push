import Foundation

public extension SinchSDKConfig {

        struct LocalizationConfig: Sendable {

        public static let defaultValue = LocalizationConfig()
        
        public var inputPlaceholderText = NSLocalizedString("label_input_placeholder", bundle: Bundle.staticBundle, comment: "")
        public var disabledChatMessageText = NSLocalizedString("label_disabled_chat_messages", bundle: Bundle.staticBundle, comment: "")
        
        public var navigationBarText = "Sinch chat"

        public var navigationBarImageViewText = NSLocalizedString("label_image", bundle: Bundle.staticBundle, comment: "")
        public var today = NSLocalizedString("label_today", bundle: Bundle.staticBundle, comment: "")
        public var yesterday = NSLocalizedString("label_yesterday", bundle: Bundle.staticBundle, comment: "")
        public var downloadFailed = NSLocalizedString("label_download_failed", bundle: Bundle.staticBundle, comment: "")
        public var tryingToDownload = NSLocalizedString("label_trying_download", bundle: Bundle.staticBundle, comment: "")
        public var connected = NSLocalizedString("label_connected", bundle: Bundle.staticBundle, comment: "")
        public var noInternetConnection = NSLocalizedString("label_no_internet_connection", bundle: Bundle.staticBundle, comment: "")
            
        public var agentHasNotJoined = NSLocalizedString("label_agent_has_not_joined", bundle: Bundle.staticBundle, comment: "")
            public var agentHasJoined = NSLocalizedString("label_agent_has_joined", bundle: Bundle.staticBundle, comment: "")
        public var alertMessageCouldNotLoadHistory = NSLocalizedString("alert_could_not_load_history", bundle: Bundle.staticBundle, comment: "")
        public var collapsedTextMessageButtonTitle = NSLocalizedString("button_title_collapsed_text_message_button", bundle: Bundle.staticBundle, comment: "")

        public var alertMessageNotSent = NSLocalizedString("alert_message_not_sent", bundle: Bundle.staticBundle, comment: "")
        public var alertTitleError = NSLocalizedString("alert_title_error", bundle: Bundle.staticBundle, comment: "")
        public var alertTitleErrorCameraDisabled = NSLocalizedString("alert_message_camera_disabled", bundle: Bundle.staticBundle, comment: "")

        public var alertButtonTitleOk = NSLocalizedString("alert_button_title_ok", bundle: Bundle.staticBundle, comment: "")
        public var menuTitleOptions = NSLocalizedString("menu_title_options", bundle: Bundle.staticBundle, comment: "")
        public var menuButtonTitleCopy = NSLocalizedString("menu_button_title_copy", bundle: Bundle.staticBundle, comment: "")
        public var menuDocument = NSLocalizedString("menu_button_title_document", bundle: Bundle.staticBundle, comment: "")
        public var menuShareLocation = NSLocalizedString("menu_button_title_share_location", bundle: Bundle.staticBundle, comment: "")
        public var menuCamera = NSLocalizedString("menu_button_title_camera", bundle: Bundle.staticBundle, comment: "")
        public var menuImageGallery = NSLocalizedString("menu_button_title_gallery", bundle: Bundle.staticBundle, comment: "")
        public var menuCancel = NSLocalizedString("button_title_cancel", bundle: Bundle.staticBundle, comment: "")
        public var locationShareCancel = NSLocalizedString("button_title_cancel", bundle: Bundle.staticBundle, comment: "")
        public var locationShare = NSLocalizedString("button_title_share_location", bundle: Bundle.staticBundle, comment: "")

        public var locationDisabledAlertTitle = NSLocalizedString("alert_title_location_disabled", bundle: Bundle.staticBundle, comment: "")
        public var locationDisabledAlertMessage = NSLocalizedString("alert_message_location_disabled", bundle: Bundle.staticBundle, comment: "")
        public var locationAlertButtonTitleOk = NSLocalizedString("alert_button_title_ok", bundle: Bundle.staticBundle, comment: "")
        public var locationAlertButtonTitleNotNow = NSLocalizedString("alert_button_title_not_now", bundle: Bundle.staticBundle, comment: "")
        public var locationAlertButtonTitleSettings = NSLocalizedString("alert_button_title_settings", bundle: Bundle.staticBundle, comment: "")
        
        public var locationOpenActionSheetTitle = NSLocalizedString("location_action_sheet_title", bundle: Bundle.staticBundle, comment: "")
        public var locationOpenAppleMaps = NSLocalizedString("location_action_sheet_apple_maps", bundle: Bundle.staticBundle, comment: "")
        public var locationOpenGoogleMaps = NSLocalizedString("location_action_sheet_google_maps", bundle: Bundle.staticBundle, comment: "")
        
        public var locationDeniedInAppAlertTitle = NSLocalizedString("alert_title_app_location_status_denied", bundle: Bundle.staticBundle, comment: "")
        public var outgoingLocationMessageTitle = NSLocalizedString("outgoing_location_message_title", bundle: Bundle.staticBundle, comment: "")
        
        public var outgoingLocationMessageButtonTitle = NSLocalizedString("outgoing_location_message_button_title", bundle: Bundle.staticBundle, comment: "")
        
        public var microphoneAlertMessage = NSLocalizedString("alert_title_microphone_disabled", bundle: Bundle.staticBundle, comment: "")
        public var microphoneAlertButtonTitleSettings = NSLocalizedString("alert_button_title_settings", bundle: Bundle.staticBundle, comment: "")
        public var recordingTitle = NSLocalizedString("recording_title", bundle: Bundle.staticBundle, comment: "")
        public var voiceMessageTitle = NSLocalizedString("voice_message_title", bundle: Bundle.staticBundle, comment: "")
        public var alertTitleHoldToRecord = NSLocalizedString("alert_message_hold_to_record", bundle: Bundle.staticBundle, comment: "")
        public var unsupportedMessageExplanation = NSLocalizedString("unsupported_message_explanation", bundle: Bundle.staticBundle, comment: "")
        
        // MARK: - Inbox
        public var inboxNavigationBarText = NSLocalizedString("inbox_title", bundle: Bundle.staticBundle, comment: "")
        public var inboxStatusText = NSLocalizedString("inbox_status", bundle: Bundle.staticBundle, comment: "")
        public var inboxStatusOpenText = NSLocalizedString("inbox_status_open", bundle: Bundle.staticBundle, comment: "")
        public var inboxStatusClosedText = NSLocalizedString("inbox_status_closed", bundle: Bundle.staticBundle, comment: "")
            
        // MARK: - InAppMessaging
        
        public var buttonTitleClose = NSLocalizedString("button_title_close", bundle: Bundle.staticBundle, comment: "")
        public var buttonTitleMaybeLater = NSLocalizedString("button_title_maybe_later", bundle: Bundle.staticBundle, comment: "")

        public var notSentStatus = NSLocalizedString("not_sent_status", bundle: Bundle.staticBundle, comment: "")
        public var sendingStatus = NSLocalizedString("sending_status", bundle: Bundle.staticBundle, comment: "")
        public var sentStatus = NSLocalizedString("sent_status", bundle: Bundle.staticBundle, comment: "")
        public var deliveredStatus = NSLocalizedString("delivered_status", bundle: Bundle.staticBundle, comment: "")
        public var seenStatus = NSLocalizedString("seen_status", bundle: Bundle.staticBundle, comment: "")

    }
}
